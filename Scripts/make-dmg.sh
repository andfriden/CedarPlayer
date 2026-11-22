#!/bin/bash
# Builds a DMG with the app and an Applications shortcut for drag-and-drop.
# Usage: Scripts/make-dmg.sh [version] [path to .app]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${CEDAR_VERSION:-1.0.1}}"
APP="${2:-build/Cedar Player.app}"
DMG="dist/CedarPlayer-$VERSION.dmg"
STAGE="build/dmg-stage"

if [ ! -d "$APP" ]; then
    echo "нет $APP — сначала соберите ./build.sh release" >&2
    exit 1
fi

rm -rf "$STAGE" "$DMG" "$DMG.sha256"
mkdir -p "$STAGE" dist
ditto "$APP" "$STAGE/Cedar Player.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "Cedar Player $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null
if [ -n "${CEDAR_SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$CEDAR_SIGN_IDENTITY" "$DMG"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "DMG $DMG"
echo "DMG SHA256 $(cut -d' ' -f1 "$DMG.sha256")"
