#!/bin/bash
# Developer ID signing and notarization; silently skips the step without secrets.
# Variables: MACOS_CERTIFICATE (base64 p12), MACOS_CERTIFICATE_PASSWORD,
# KEYCHAIN_PASSWORD, CEDAR_SIGN_IDENTITY, APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/Cedar Player.app}"
if [ -z "${MACOS_CERTIFICATE:-}" ]; then
    echo "SIGN skipped: MACOS_CERTIFICATE не задан"
    exit 0
fi

KEYCHAIN="${CEDAR_KEYCHAIN:-build/cedar-signing.keychain-db}"
CERT="${RUNNER_TEMP:-/tmp}/cedar-cert.p12"
echo "$MACOS_CERTIFICATE" | base64 --decode > "$CERT"

security create-keychain -p "${KEYCHAIN_PASSWORD:-cedar}" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "${KEYCHAIN_PASSWORD:-cedar}" "$KEYCHAIN"
security import "$CERT" -k "$KEYCHAIN" -P "${MACOS_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign
security list-keychains -d user -s "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -k "${KEYCHAIN_PASSWORD:-cedar}" "$KEYCHAIN" >/dev/null

IDENTITY="${CEDAR_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | awk 'NR==1 {print $2}')
fi
if [ -z "$IDENTITY" ]; then
    echo "SIGN failed: сертификат не найден" >&2
    exit 1
fi

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
    NOTARIZE_ZIP="${RUNNER_TEMP:-/tmp}/CedarPlayer-notarize.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait
    xcrun stapler staple "$APP"
    echo "SIGN notarized"
else
    echo "SIGN signed without notarization"
fi
