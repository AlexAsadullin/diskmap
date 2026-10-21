#!/bin/bash
# Builds DiskMap.app, packs it as DiskMap.zip and DiskMap.dmg and publishes a GitHub Release.
# Asset names carry no version, so the README link
#   https://github.com/AlexAsadullin/diskmap/releases/latest/download/DiskMap.zip
# always points at the newest release.
#
#   VERSION=1.0.1 scripts/release.sh
#   SIGN_IDENTITY=… NOTARY_PROFILE=… VERSION=1.0.1 scripts/release.sh   (signed + notarized)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:?set VERSION, e.g. VERSION=1.0.1}"
TAG="v$VERSION"
export VERSION

scripts/build_app.sh
if [ -n "${NOTARY_PROFILE:-}" ]; then
    ditto -c -k --keepParent build/DiskMap.app build/notarize.zip
    xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple build/DiskMap.app
    rm build/notarize.zip
fi
rm -f build/DiskMap.zip
ditto -c -k --sequesterRsrc --keepParent build/DiskMap.app build/DiskMap.zip
scripts/make_dmg.sh

NOTES="build/release-notes.md"
cat > "$NOTES" <<NOTES_EOF
## DiskMap $VERSION

**Download:** [DiskMap.zip](https://github.com/AlexAsadullin/diskmap/releases/download/$TAG/DiskMap.zip) (app) or [DiskMap.dmg](https://github.com/AlexAsadullin/diskmap/releases/download/$TAG/DiskMap.dmg) (disk image).

macOS 13 or later, Apple Silicon and Intel (universal).

How to install and open the app the first time: see [Download and install](https://github.com/AlexAsadullin/diskmap#download) in the README.
NOTES_EOF

git tag -f "$TAG"
git push -f origin "$TAG"
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" build/DiskMap.zip build/DiskMap.dmg --clobber
else
    gh release create "$TAG" build/DiskMap.zip build/DiskMap.dmg --title "DiskMap $VERSION" --notes-file "$NOTES" --latest
fi
echo "==> https://github.com/AlexAsadullin/diskmap/releases/tag/$TAG"
