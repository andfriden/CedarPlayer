#!/bin/bash
# Сборка Cedar Player.app из SwiftPM-пакета.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Cedar Player.app"

TARGET="${CEDAR_DEPLOYMENT_TARGET:-13.0}"
if [ "${CEDAR_UNIVERSAL:-0}" = "1" ]; then
    echo "Универсальная сборка x86_64 + arm64 (macOS $TARGET)…"
    swift build -c "$CONFIG" --triple "x86_64-apple-macosx$TARGET"
    X86_BIN="$(swift build -c "$CONFIG" --triple "x86_64-apple-macosx$TARGET" --show-bin-path)/CedarPlayer"
    swift build -c "$CONFIG" --triple "arm64-apple-macosx$TARGET"
    ARM_BIN="$(swift build -c "$CONFIG" --triple "arm64-apple-macosx$TARGET" --show-bin-path)/CedarPlayer"
    mkdir -p build
    BIN="build/CedarPlayer-universal"
    lipo -create "$X86_BIN" "$ARM_BIN" -output "$BIN"
else
    swift build -c "$CONFIG"
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/CedarPlayer"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CedarPlayer"
if [ "${BIN##*/}" = "CedarPlayer-universal" ]; then
    rm -f "$BIN"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
VERSION="${CEDAR_VERSION:-1.1.0}"
BUILD_NUMBER="${CEDAR_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" >/dev/null
if [ -d Resources/en.lproj ]; then
    cp -R Resources/en.lproj "$APP/Contents/Resources/"
fi
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Собрано: $APP"
