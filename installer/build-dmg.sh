#!/bin/sh
# build-dmg.sh <app-path> <volume-name> <output.dmg>
set -eu
APP=$1; VOL=$2; OUT=$3
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"
