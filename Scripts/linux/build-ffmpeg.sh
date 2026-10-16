#!/usr/bin/env bash
set -euo pipefail
cd /workspace
version=$(python3 -c 'import json;print(json.load(open("Linux/dependencies.lock.json"))["ffmpeg"]["version"])')
prefix=/workspace/Build/Linux/vcpkg/installed/x64-linux
mkdir -p Build/Linux/ffmpeg-build
cd Build/Linux/ffmpeg-build
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
../src/ffmpeg-"$version"/configure \
  --prefix="$prefix" --enable-static --disable-shared --enable-pic \
  --disable-everything --disable-autodetect --disable-programs --disable-doc \
  --disable-network --disable-avdevice --disable-swresample --disable-swscale \
  --enable-avcodec --enable-avformat --enable-avfilter --enable-pthreads \
  --enable-libdrm --enable-vaapi --enable-zlib \
  --enable-cuda --enable-ffnvcodec --enable-nvenc --enable-nvdec --enable-amf \
  --extra-cflags="-I$prefix/include" \
  --enable-decoder=h264,hevc --enable-parser=h264,hevc \
  --enable-encoder=h264_vaapi,hevc_vaapi,h264_nvenc,hevc_nvenc,h264_amf,hevc_amf \
  --enable-hwaccel=h264_vaapi,hevc_vaapi,h264_nvdec,hevc_nvdec \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,h264_metadata,hevc_metadata \
  --enable-muxer=mp4 --enable-protocol=file \
  --enable-filter=buffer,buffersink,hwmap,scale_vaapi
make -j4
make install
