#!/bin/zsh
# Installs the latest Nebula release into /Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/rune/nebula/main/scripts/install.sh | zsh
# curl doesn't mark what it downloads as quarantined, so Gatekeeper doesn't block the un-notarized app.
set -euo pipefail

DMG_URL=$(curl -fsSL https://api.github.com/repos/rune/nebula/releases/latest \
	| sed -nE 's/.*"browser_download_url": *"([^"]*\.dmg)".*/\1/p' | head -1)
[[ -n "$DMG_URL" ]] || { echo "Couldn't find a Nebula release to download." >&2; exit 1; }

WORK=$(mktemp -d)
MOUNT="$WORK/mount"
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null; rm -rf "$WORK"' EXIT

echo "Downloading ${DMG_URL:t}…"
curl -fL --progress-bar "$DMG_URL" -o "$WORK/Nebula.dmg"
hdiutil attach "$WORK/Nebula.dmg" -nobrowse -readonly -mountpoint "$MOUNT" -quiet

if pgrep -xq Nebula; then
	osascript -e 'quit app "Nebula"'
	while pgrep -xq Nebula; do sleep 0.2; done
fi
rm -rf /Applications/Nebula.app
ditto "$MOUNT/Nebula.app" /Applications/Nebula.app

echo "Installed Nebula in /Applications. Opening it…"
open /Applications/Nebula.app
