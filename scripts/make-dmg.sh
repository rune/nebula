#!/bin/zsh
# Builds Nebula in Release, checks its signature and packs it into dist/Nebula-<version>.dmg.
# Usage: scripts/make-dmg.sh   (SIGN_IDENTITY overrides the signing identity for the DMG)
set -euo pipefail

ROOT=${0:A:h:h}
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' "$ROOT/project.yml")
DATA="$ROOT/build/ReleaseData"
APP="$DATA/Build/Products/Release/Nebula.app"
DMG="$ROOT/dist/Nebula-$VERSION.dmg"
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}

echo "Building Nebula $VERSION…"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" >/dev/null
xcodebuild -project "$ROOT/Nebula.xcodeproj" -scheme Nebula -configuration Release \
	-derivedDataPath "$DATA" -destination 'platform=macOS' build >"$ROOT/build/release.log" 2>&1 \
	|| { grep -E "error:" "$ROOT/build/release.log" | sort -u; exit 1; }

codesign --verify --deep --strict "$APP"
echo "Signed: $(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$ROOT/dist"
rm -f "$DMG"
hdiutil create -volname "Nebula" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
[[ -n "$IDENTITY" ]] && codesign --sign "$IDENTITY" --timestamp=none "$DMG"
echo "Wrote $DMG ($(du -h "$DMG" | cut -f1))"
