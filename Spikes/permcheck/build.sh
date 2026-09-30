#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="permcheck.app"
swiftc -swift-version 5 main.swift -o permcheck-bin \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
mv permcheck-bin "$APP/Contents/MacOS/permcheck"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>permcheck</string>
<key>CFBundleExecutable</key><string>permcheck</string>
<key>CFBundleIdentifier</key><string>com.soundboard.permcheck</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSMicrophoneUsageDescription</key><string>diagnostic</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier com.soundboard.permcheck "$APP" 2>/dev/null
echo "built $APP"
