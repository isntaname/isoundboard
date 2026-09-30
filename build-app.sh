#!/bin/bash
# Package the SwiftUI app as a real .app bundle.
#
# The bundle identity matters: macOS attaches Microphone / Input Monitoring /
# Accessibility grants to it. A bare SPM binary has no bundle ID and inherits
# whatever launched it, so permissions would follow your terminal instead.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="debug"
INSTALL=false
UNIVERSAL=false
for arg in "$@"; do
    case "$arg" in
        release|debug) CONFIG="$arg" ;;
        --install) INSTALL=true ;;
        # Apple silicon + Intel in one binary. What published releases use.
        --universal) UNIVERSAL=true ;;
        *) echo "usage: $0 [debug|release] [--universal] [--install]"; exit 1 ;;
    esac
done

# Published releases pass VERSION=1.2.0; local builds don't need one.
VERSION="${VERSION:-0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

APP="build/iSoundboard.app"

echo "building ($CONFIG)…"
ARCH_FLAGS=()
if [ "$UNIVERSAL" = true ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product SoundboardApp

BIN=$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product SoundboardApp --show-bin-path)/SoundboardApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iSoundboard"

# The audio driver ships inside the app; the app installs it on first launch.
./Driver/build-driver.sh
mkdir -p "$APP/Contents/Library/Driver"
cp -R build/driver/iSoundboard.driver "$APP/Contents/Library/Driver/"

# App icon. Source and generator live in Resources/Icon; regenerate the .icns
# if it is missing (e.g. after a clean checkout that skipped build output).
ICON="Resources/Icon/AppIcon.icns"
if [ ! -f "$ICON" ]; then
    swift Resources/Icon/make-icon.swift
fi
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>iSoundboard</string>
    <key>CFBundleDisplayName</key><string>iSoundboard</string>
    <key>CFBundleExecutable</key><string>iSoundboard</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>io.github.isntaname.isoundboard</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0. Audio driver based on BlackHole by Existential Audio.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>iSoundboard mixes your voice with your sound clips so your teammates hear both.</string>
</dict>
</plist>
PLIST

# Signing. Unsigned arm64 binaries will not run at all.
#
# Which identity is used matters for permissions, not just for launching:
# macOS ties Input Monitoring / Accessibility grants to the app's code identity.
# An ad-hoc signature is identified by its hash, which changes on EVERY rebuild,
# so each rebuild looks like a brand-new app and previous approvals stop
# applying — the app still appears (ticked) in System Settings while the
# keyboard tap silently fails.
#
# Set SOUNDBOARD_SIGN_IDENTITY to a real signing certificate to avoid that:
#   export SOUNDBOARD_SIGN_IDENTITY="Apple Development: you@example.com"
# Create one in Keychain Access > Certificate Assistant > Create a Certificate
# (type: Code Signing, self-signed), or use a Developer ID if you have one.
# Prefer a real certificate, falling back to ad-hoc. Auto-detect one so grants
# survive rebuilds without the user having to configure anything.
IDENTITY="${SOUNDBOARD_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -oE '"(Apple Development|Developer ID Application|Mac Developer): [^"]+"' \
        | head -1 | tr -d '"')
    if [ -n "$DETECTED" ]; then
        IDENTITY="$DETECTED"
        echo "signing with detected identity: $IDENTITY"
    else
        IDENTITY="-"
    fi
fi

# Nested code first: the app's signature covers the driver's, not the reverse.
codesign --force --sign "$IDENTITY" "$APP/Contents/Library/Driver/iSoundboard.driver"
codesign --force --sign "$IDENTITY" --identifier io.github.isntaname.isoundboard "$APP"

if [ "$IDENTITY" = "-" ]; then
    echo
    echo "  NOTE: signed ad-hoc. Permissions granted to this build will stop"
    echo "        applying after the next rebuild — you will have to remove and"
    echo "        re-add iSoundboard in System Settings each time."
    echo "        Set SOUNDBOARD_SIGN_IDENTITY to a stable certificate to fix this."
fi

if [ "$INSTALL" = true ]; then
    # A stable location in /Applications makes the app easy to find in the
    # Settings "+" picker, and keeps its path steady for TCC.
    rm -rf /Applications/iSoundboard.app
    cp -R "$APP" /Applications/iSoundboard.app
    APP="/Applications/iSoundboard.app"
    echo "installed to /Applications/iSoundboard.app"
fi

echo
echo "built: $APP"
echo "run:   open \"$APP\""
echo
echo "  Launch it with 'open', never by running the binary directly —"
echo "  a binary started from a shell inherits the TERMINAL's permissions,"
echo "  so it will never prompt and will misreport what it has access to."
