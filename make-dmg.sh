#!/bin/bash
# Build a universal release and wrap it in a drag-to-Applications disk image.
#
#   VERSION=1.0.0 ./make-dmg.sh      ->  build/iSoundboard-1.0.0.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.0.0 ./make-dmg.sh}"
export VERSION

./build-app.sh release --universal

DMG="build/iSoundboard-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R build/iSoundboard.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "iSoundboard" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null
shasum -a 256 "$DMG"
echo "built: $DMG"
