# libvlc (WebPorn media)

The media engine of [WebPorn](https://github.com/wowodymyr/WebPorn) (modern WebKit for
jailbroken iOS 8): `<video>` / `<audio>`, HLS and Media Source Extensions played by
libVLC 3.0.18 (MobileVLCKit 3.5.1, the last release for iOS 8.4) with VideoToolbox decoding
and VLC's OpenGL ES output, on the GPU.

- `libWebPornMedia.dylib` (`wpmedia.m`): a small C ABI (`wpmedia.h`, version 5) over libvlc.
  WebPorn's WebCore (`MediaPlayerPrivateWebPorn`) dlopens it; no C++ crosses the boundary.
  It plays URLs, streams bytes fetched by WebCore's own loader (cookies, `blob:`, CORS),
  proxies HLS through that loader, muxes MSE source buffers into Matroska for VLC, renders
  into a CALayer, gives canvas frames (`drawImage(video)`) and runs full screen in its own window
  (turns with the device; Done, play/pause, ±10 s, scrubber with elapsed / remaining time).
- `MobileVLCKit.framework`: VideoLAN's MobileVLCKit 3.5.1, armv7 slice, install name moved
  to `/var/webporn/lib`.

On an iPhone 5 (A6): H.264 720p/1080p30, VP8/VP9 720p in real time; YouTube (m.youtube.com,
MSE) 720p30 with seeking and audio.

## Install

Release: [libvlc 1.0.1](https://github.com/wowodymyr/libvlc/releases/tag/1.0.1) —
`net.webporn.libvlc_1.0.1_iphoneos-arm.deb`. Install it together with the `net.webporn`
package (which depends on it) and TLSFix; see the WebPorn README. Files go to
`/var/webporn/lib/libWebPornMedia.dylib` and `/var/webporn/lib/MobileVLCKit.framework/`.
Without this package WebPorn runs without a media engine (no video or audio).

armv7 / iOS 8 only (tested on iOS 8.4.1).

## Build

Needs clang, [Theos](https://theos.dev)' iOS toolchain (ld64, ldid, install_name_tool) in
`$THEOS` (default `~/theos`), `llvm-lipo`, `dpkg-deb` and an iPhoneOS 9.3 SDK in `$SDK`
(default `$THEOS/sdks/iPhoneOS9.3.sdk`; theos/sdks lacks `usr/lib/system/liblaunch.tbd`,
copy it from the 10.3 SDK).

```sh
./build.sh      # downloads MobileVLCKit 3.5.1 (prepare-vlc.sh, sha256-checked)
                # -> build/net.webporn.libvlc_<version>_iphoneos-arm.deb
```

Debug switches on the device: `/var/webporn/wpmedia-debug` (logs and the streams libVLC got,
in `/var/mobile/Media/webporn/`), `/var/webporn/media-direct` (read by WebPorn's WebCore: libVLC fetches URLs itself).

## License

GNU LGPL 2.1 (`COPYING.LIB`), the license of WebKit's WebCore and of libVLC itself;
`LICENSE-APPLE` (BSD) as in WebKit. MobileVLCKit / libVLC are © VideoLAN and the VLC
authors, LGPL 2.1 or later; source at https://code.videolan.org/videolan/VLCKit (tag 3.5.1)
and https://code.videolan.org/videolan/vlc (3.0.18).
