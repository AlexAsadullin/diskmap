#!/bin/bash
# Packs build/DiskMap.app into build/DiskMap-<version>.dmg and, if credentials are given, notarizes it.
#
#   scripts/make_dmg.sh
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=diskmap scripts/make_dmg.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials diskmap --apple-id you@example.com --team-id TEAMID
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
APP="build/DiskMap.app"
DMG="build/DiskMap.dmg"
STAGE="build/dmg"

[ -d "$APP" ] || { echo "Run scripts/build_app.sh first"; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp scripts/diskmap "$STAGE/diskmap (command line tool)"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DiskMap" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi
echo "==> $DMG"
