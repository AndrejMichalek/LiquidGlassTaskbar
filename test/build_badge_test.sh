#!/bin/bash
# Builds the BadgeTest.app used to test the notification highlight.
set -euo pipefail
cd "$(dirname "$0")"

APP=BadgeTest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc badge_test.swift -o "$APP/Contents/MacOS/BadgeTest"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>BadgeTest</string>
	<key>CFBundleIdentifier</key><string>sk.michalek.BadgeTest</string>
	<key>CFBundleName</key><string>BadgeTest</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Done: $APP"
