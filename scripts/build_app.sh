#!/bin/bash
# Builds build/DiskMap.app: universal (arm64 + x86_64) release binary, icon, Info.plist, signature.
#
#   scripts/build_app.sh                 ad-hoc signature (runs on this Mac)
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build_app.sh
#                                        Developer ID signature with hardened runtime (for notarization)
#   ARCHS="arm64" scripts/build_app.sh   build a single architecture
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/DiskMap.app"

binaries=()
for arch in $ARCHS; do
    echo "==> Building $arch"
    swift build -c release --product DiskMap --triple "$arch-apple-macosx13.0" --scratch-path ".build/$arch"
    binaries+=(".build/$arch/release/DiskMap")
done

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/DiskMap"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift scripts/make_icon.swift build/icon-1024.png >/dev/null
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
lipo -info "$APP/Contents/MacOS/DiskMap"
echo "==> Done: $APP"
