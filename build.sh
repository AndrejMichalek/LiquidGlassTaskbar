#!/bin/bash
# Builds LiquidGlassTaskbar.app into ./build using SwiftPM (no Xcode needed).
# Signs with the "LiquidGlassTaskbar Signing" self-signed certificate when present
# in the keychain, so the Accessibility permission survives rebuilds.
# Override with CODESIGN_ID; falls back to ad-hoc "-".
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${CODESIGN_ID:-}" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "LiquidGlassTaskbar Signing"; then
        CODESIGN_ID="LiquidGlassTaskbar Signing"
    else
        CODESIGN_ID="-"
    fi
fi

swift build -c release

APP="build/LiquidGlassTaskbar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiquidGlassTaskbar "$APP/Contents/MacOS/LiquidGlassTaskbar"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$CODESIGN_ID" "$APP"
echo "Signed with identity: $CODESIGN_ID"

echo "Done: $APP"
echo "Run:  open $APP"
