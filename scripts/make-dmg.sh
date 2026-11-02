#!/bin/zsh
# Builds Nebula in Release, checks its signature and packs it into dist/Nebula-<version>.dmg.
# Usage: scripts/make-dmg.sh   (SIGN_IDENTITY overrides the signing identity)
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
DATA="$ROOT/build/ReleaseData"
APP="$DATA/Build/Products/Release/Nebula.app"
DMG="$ROOT/dist/Nebula-$VERSION.dmg"
# Ad-hoc by default: a free account's Apple Development certificates keep getting revoked, and an app signed
# with a revoked one is reported as malware. An ad-hoc signature has no certificate to revoke.
IDENTITY=${SIGN_IDENTITY:--}

assert_not_revoked() {
	if spctl --assess -vv "$@" 2>&1 | grep -q REVOKED; then
		echo "$@[-1] is signed with a revoked certificate." >&2
		exit 1
	fi
}

echo "Building Nebula $VERSION…"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" >/dev/null
xcodebuild -project "$ROOT/Nebula.xcodeproj" -scheme Nebula -configuration Release \
	-derivedDataPath "$DATA" -destination 'platform=macOS' \
	CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" build >"$ROOT/build/release.log" 2>&1 \
	|| { grep -E "error:" "$ROOT/build/release.log" | sort -u; exit 1; }

codesign --verify --deep --strict "$APP"
assert_not_revoked --type exec "$APP"
echo "Signed: $(codesign -dv "$APP" 2>&1 | sed -nE 's/^(Authority|Signature)=//p' | head -1)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -volname "Nebula" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --sign "$IDENTITY" --timestamp=none "$DMG"
assert_not_revoked --type open --context context:primary-signature "$DMG"
echo "Wrote $DMG ($(du -h "$DMG" | cut -f1))"
