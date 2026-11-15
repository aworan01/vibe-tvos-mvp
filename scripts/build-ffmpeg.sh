#!/bin/bash
set -euo pipefail

revision=0706d0ab1fadddf4a32fe7e589b2cff623475274
platform="${1:?expected appletvos, appletvsimulator, or macosx}"
case "$platform" in
  appletvos) target=arm64-apple-tvos17.0 ;;
  appletvsimulator) target="$(uname -m)-apple-tvos17.0-simulator" ;;
  macosx) target="$(uname -m)-apple-macos14.0" ;;
  *) exit 2 ;;
esac
root="$(pwd)"
source_dir="$root/build/ffmpeg-source"
if [[ ! -f "$source_dir/configure" ]]; then
  mkdir -p "$source_dir"
  curl --fail --silent --show-error --location --retry 3 \
    "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/$revision" |
    tar -xz --strip-components=1 -C "$source_dir"
fi
prefix="$root/build/ffmpeg/$platform"
mkdir -p "$prefix/obj" "$root/build/notices"
cp "$source_dir/COPYING.LGPLv2.1" "$root/build/notices/FFmpeg-LGPLv2.1.txt"
printf 'FFmpeg source: https://github.com/FFmpeg/FFmpeg/tree/%s\nBuild configuration: https://github.com/aworan01/vibe-tvos-mvp/blob/main/scripts/build-ffmpeg.sh\n' "$revision" > "$root/build/notices/FFmpeg-source.txt"

sdk="$(xcrun --sdk "$platform" --show-sdk-path)"
cc="$(xcrun --sdk "$platform" --find clang)"
cd "$prefix/obj"
mkdir -p pkgconfig
cat > pkgconfig/libxml-2.0.pc <<EOF
Name: libxml2
Description: libxml2 from the Apple SDK
Version: 2.9
Cflags: -I$sdk/usr/include/libxml2
Libs: -lxml2
EOF
export PKG_CONFIG_LIBDIR="$PWD/pkgconfig"
"$source_dir/configure" \
  --prefix="$prefix" --target-os=darwin --arch="${target%%-*}" --enable-cross-compile \
  --cc="$cc" --sysroot="$sdk" \
  --extra-cflags="-target $target -I$sdk/usr/include/libxml2 -fvisibility=hidden" \
  --extra-ldflags="-target $target" \
  --disable-autodetect --disable-everything --disable-programs --disable-doc \
  --disable-avdevice --disable-avfilter --disable-swresample --disable-swscale \
  --disable-x86asm --disable-debug --enable-pic --enable-network \
  --enable-libxml2 --enable-securetransport \
  --enable-protocol=http,https,tcp,tls \
  --enable-demuxer=dash,mov --enable-muxer=mpegts \
  --enable-parser=h264,hevc,aac,ac3 --enable-decoder=h264,hevc,aac,ac3,eac3 \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb
grep -q '^#define CONFIG_HTTPS_PROTOCOL 1$' config_components.h
grep -q '^#define CONFIG_DASH_DEMUXER 1$' config_components.h
make -j "$(sysctl -n hw.logicalcpu)" > "$prefix/build.log" 2>&1 || { tail -100 "$prefix/build.log"; exit 1; }
make install > "$prefix/install.log" 2>&1 || { tail -100 "$prefix/install.log"; exit 1; }

