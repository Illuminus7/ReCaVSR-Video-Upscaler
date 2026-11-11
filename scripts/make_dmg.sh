#!/bin/bash
# Packs build/ReCaVSR.app into build/ReCaVSR-<version>.dmg: the app, a link to
# /Applications for drag-and-drop installation, and the app's licence (MIT). Run scripts/build_app.sh first.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/ReCaVSR.app"
[ -d "$APP" ] || { echo "Build the app first: scripts/build_app.sh" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="build/ReCaVSR-$VERSION.dmg"

# Staged outside iCloud Drive, without extended attributes, so the copy inside the image
# keeps a valid signature and carries nothing from this Mac.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/ReCaVSR"
ditto --noextattr --norsrc "$APP" "$WORK/ReCaVSR/ReCaVSR.app"
codesign --verify --deep --strict "$WORK/ReCaVSR/ReCaVSR.app"
ln -s /Applications "$WORK/ReCaVSR/Applications"
cp LICENSE "$WORK/ReCaVSR/LICENSE.txt"

rm -f "$DMG"
hdiutil create -quiet -volname "ReCaVSR $VERSION" -srcfolder "$WORK/ReCaVSR" \
    -fs APFS -format ULFO -ov "$WORK/ReCaVSR.dmg"
mv "$WORK/ReCaVSR.dmg" "$DMG"
hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
