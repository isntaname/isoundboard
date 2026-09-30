#!/bin/bash
# Build iSoundboard's audio driver from the vendored BlackHole source.
# Output: build/driver/iSoundboard.driver. Skipped when already up to date.
set -euo pipefail
cd "$(dirname "$0")/.."

# Bump when our build of the driver changes, so installed copies get replaced.
DRIVER_REVISION=2

SRC=Driver/BlackHole
OUT=build/driver/iSoundboard.driver
ICON=Resources/Icon/AppIcon.icns
VERSION="$(tr -d '[:space:]' < "$SRC/VERSION").$DRIVER_REVISION"
BUNDLE_ID=io.github.isntaname.isoundboard.driver

if [ -f "$OUT/Contents/Info.plist" ] \
   && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/Contents/Info.plist")" = "$VERSION" ] \
   && [ -z "$(find "$SRC" "$ICON" "Driver/build-driver.sh" -newer "$OUT/Contents/Info.plist" -print -quit)" ]; then
    echo "driver up to date ($VERSION)"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp -R "$SRC/." "$WORK/"

# Two names are hard-coded rather than set by macros. Point them at ours.
C="$WORK/BlackHole/BlackHole.c"
sed -i '' -e 's/CFSTR("BlackHole Box")/CFSTR(kDriver_Name " Box")/' \
          -e 's/CFSTR("Existential Audio Inc.")/CFSTR(kManufacturer_Name)/' "$C"
if grep -q 'CFSTR("BlackHole Box")\|CFSTR("Existential Audio Inc.")' "$C"; then
    echo "error: BlackHole.c changed; update the name patches in Driver/build-driver.sh" >&2
    exit 1
fi

xcodebuild -quiet -project "$WORK/BlackHole.xcodeproj" -configuration Release -target BlackHole \
    SYMROOT="$WORK/build" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
    PRODUCT_NAME=iSoundboard PRODUCT_BUNDLE_IDENTIFIER=$BUNDLE_ID \
    GCC_PREPROCESSOR_DEFINITIONS='$GCC_PREPROCESSOR_DEFINITIONS kDriver_Name=\"iSoundboard\" kDevice_Name=\"iSoundboard\" kManufacturer_Name=\"iSoundboard\" kHas_Driver_Name_Format=false kPlugIn_BundleID=\"io.github.isntaname.isoundboard.driver\" kPlugIn_Icon=\"iSoundboard.icns\" kNumber_Of_Channels=2'

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
cp -R "$WORK/build/Release/iSoundboard.driver" "$OUT"

# Their branding and docs out, our icon in. LICENSE stays: the GPL requires it.
rm -f "$OUT/Contents/Resources/BlackHole.icns" "$OUT/Contents/Resources/README.md" \
      "$OUT/Contents/Resources/CHANGELOG.md"
cp "$ICON" "$OUT/Contents/Resources/iSoundboard.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
                        -c "Set :CFBundleShortVersionString $VERSION" "$OUT/Contents/Info.plist"
echo "built driver $VERSION"
