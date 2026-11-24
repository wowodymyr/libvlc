#!/bin/bash
# libVLC for the media engine: MobileVLCKit 3.5.1 (libvlc 3.0.x, the last release
# with an iOS 8.4 deployment target), thinned to one arch and renamed to its
# install location on the device.
#   prepare-vlc.sh <arch> <tag>      e.g. armv7 armv7-ios8
# Output: build/<tag>/MobileVLCKit.framework/{MobileVLCKit,Headers}
# The device copy must be signed there (ldid -S), like every other binary.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
ARCH=$1 TAG=$2
VER=3.5.1
URL=https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.5.1-34408b84-e9eceaed.tar.xz
SHA=1acd2f8c17b1cd3a5d48961b51ecf12c3ac83fb6ab5f60c1a86e9f2d7381d251
DL=$ROOT/build/dl
T=${THEOS:-$HOME/theos}/toolchain/linux/iphone/bin
mkdir -p "$DL"
[ -f "$DL/MobileVLCKit-$VER.tar.xz" ] || curl -sSL -o "$DL/MobileVLCKit-$VER.tar.xz" "$URL"
echo "$SHA  $DL/MobileVLCKit-$VER.tar.xz" | sha256sum -c --quiet
SRC=$DL/x/MobileVLCKit-binary/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework
[ -d "$SRC" ] || { mkdir -p "$DL/x"; tar -C "$DL/x" -xJf "$DL/MobileVLCKit-$VER.tar.xz"; }
OUT=$ROOT/build/$TAG/MobileVLCKit.framework
rm -rf "$OUT"; mkdir -p "$OUT"
cp -r "$SRC/Headers" "$OUT/"
${LIPO:-llvm-lipo} "$SRC/MobileVLCKit" -thin "$ARCH" -output "$OUT/MobileVLCKit"
"$T/codesign_allocate" -r -i "$OUT/MobileVLCKit" -o "$OUT/MobileVLCKit.unsigned"
mv "$OUT/MobileVLCKit.unsigned" "$OUT/MobileVLCKit"
"$T/install_name_tool" -id /var/webporn/lib/MobileVLCKit.framework/MobileVLCKit "$OUT/MobileVLCKit"
echo "$OUT"
