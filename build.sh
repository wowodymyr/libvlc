#!/bin/bash
# Build libWebPornMedia.dylib (wpmedia.h over libVLC) for armv7 iOS 8 and package it
# with MobileVLCKit's libvlc as a .deb (build/net.webporn.libvlc_<version>_iphoneos-arm.deb).
#   ./build.sh
# Needs: clang (any recent), Theos' iOS toolchain (ld64, ldid, install_name_tool) in
# $THEOS (default ~/theos), an iPhoneOS 9.3 SDK in $SDK, llvm-lipo, dpkg-deb.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
THEOS=${THEOS:-$HOME/theos}
SDK=${SDK:-$THEOS/sdks/iPhoneOS9.3.sdk}
T=$THEOS/toolchain/linux/iphone/bin
B=$ROOT/build
VLC=$B/armv7-ios8/MobileVLCKit.framework
[ -f "$SDK/usr/lib/system/liblaunch.tbd" ] || {
    echo "$SDK lacks usr/lib/system/liblaunch.tbd (theos/sdks omits it; copy it from iPhoneOS10.3.sdk)" >&2; exit 1; }
mkdir -p "$B"
[ -f "$VLC/MobileVLCKit" ] || THEOS=$THEOS "$ROOT/prepare-vlc.sh" armv7 armv7-ios8
# Compile with ARC, link without it: clang would want libarclite, which the
# open-source toolchain lacks.
clang -target armv7-apple-ios8.4 -isysroot "$SDK" -O2 -Wall -fobjc-arc -fvisibility=default \
    -I"$VLC/Headers" -c "$ROOT/wpmedia.m" -o "$B/wpmedia.o"
clang -target armv7-apple-ios8.4 -isysroot "$SDK" --ld-path="$T/ld" -dynamiclib \
    -install_name /var/webporn/lib/libWebPornMedia.dylib -exported_symbols_list "$ROOT/exports.txt" \
    -framework UIKit -framework QuartzCore -framework ImageIO -framework CoreGraphics -framework Foundation "$VLC/MobileVLCKit" "$B/wpmedia.o" \
    -o "$B/libWebPornMedia.dylib" 2>"$B/ld.log" || { cat "$B/ld.log" >&2; exit 1; }

# Package: both images live next to the engine in /var/webporn/lib, where WebCore
# dlopens libWebPornMedia.dylib.
P=$B/pkg
rm -rf "$P"; mkdir -p "$P/DEBIAN" "$P/var/webporn/lib/MobileVLCKit.framework"
cp "$ROOT/layout/DEBIAN/control" "$P/DEBIAN/control"
cp "$VLC/MobileVLCKit" "$P/var/webporn/lib/MobileVLCKit.framework/MobileVLCKit"
cp "$B/libWebPornMedia.dylib" "$P/var/webporn/lib/libWebPornMedia.dylib"
"$T/ldid" -S "$P/var/webporn/lib/MobileVLCKit.framework/MobileVLCKit" "$P/var/webporn/lib/libWebPornMedia.dylib"
SIZE=$(du -sk "$P/var" | cut -f1)
echo "Installed-Size: $SIZE" >> "$P/DEBIAN/control"
PKG=$(sed -n 's/^Package: //p' "$P/DEBIAN/control")
VER=$(sed -n 's/^Version: //p' "$P/DEBIAN/control")
find "$P" -exec touch -h -d @0 {} +
dpkg-deb --root-owner-group -Zgzip -b "$P" "$B/${PKG}_${VER}_iphoneos-arm.deb" >/dev/null
echo "$B/${PKG}_${VER}_iphoneos-arm.deb"
