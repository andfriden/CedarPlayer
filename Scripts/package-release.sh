#!/bin/bash
# Builds a zip with the app and a checksum.
# Usage: Scripts/package-release.sh [version]
# SKIP_BUILD=1 — package the already built and signed app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${CEDAR_VERSION:-1.2.0}}"
APP="build/Cedar Player.app"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    CEDAR_VERSION="$VERSION" CEDAR_UNIVERSAL="${CEDAR_UNIVERSAL:-1}" ./build.sh release
fi

if [ ! -d "$APP" ]; then
    echo "нет $APP — сначала соберите ./build.sh release" >&2
    exit 1
fi

SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
if [ "$SHORT" != "$VERSION" ]; then
    echo "версия в бандле $SHORT не совпадает с $VERSION" >&2
    exit 1
fi

mkdir -p dist
ZIP="dist/CedarPlayer-$VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "PACKAGE $ZIP"
echo "SHA256 $(cut -d' ' -f1 "$ZIP.sha256")"
Scripts/make-dmg.sh "$VERSION" "$APP"
