#!/usr/bin/env bash
set -euo pipefail
cd /workspace
prefix=/workspace/Build/Linux/vcpkg/installed/x64-linux
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
mkdir -p Build/Linux/bin
g++ -std=c++17 -O2 -Wall -Wextra -Werror Linux/tests/p0_media.cpp \
  -I"$prefix/include" $(pkg-config --cflags libdrm libdrm_amdgpu) \
  -Wl,--start-group "$prefix/lib/libavfilter.a" "$prefix/lib/libavformat.a" \
  "$prefix/lib/libavcodec.a" "$prefix/lib/libavutil.a" "$prefix/lib/libyuv.a" \
  -Wl,--end-group $(pkg-config --libs libva libva-drm libdrm libdrm_amdgpu) -lz -lm -ldl -pthread \
  -o Build/Linux/bin/p0-media
readelf -d Build/Linux/bin/p0-media > Build/Linux/logs/p0-needed.txt
if grep -E 'NEEDED.*lib(av|sw)' Build/Linux/logs/p0-needed.txt; then
  echo 'Unexpected system FFmpeg dependency' >&2
  exit 1
fi
hw=/workspace/Build/Linux/src/hwcodec
g++ -std=c++17 -O2 -include cstdint Linux/tests/p0_cpu.cpp \
  "$hw/cpp/ffmpeg_ram/ffmpeg_ram_encode.cpp" "$hw/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp" \
  "$hw/cpp/common/util.cpp" "$hw/cpp/common/log.cpp" "$hw/cpp/common/platform/linux/linux.cpp" \
  "$hw/cpp/mux/mux.cpp" -I"$hw/cpp/common" -I"$hw/cpp/common/platform/linux" \
  -I"$hw/cpp/ffmpeg_ram" -I"$hw/cpp/mux" \
  -I"$hw/externals/nv-codec-headers_n12.1.14.0/include/ffnvcodec" -I"$prefix/include" \
  -Wl,--start-group "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" \
  "$prefix/lib/libavutil.a" "$prefix/lib/libyuv.a" -Wl,--end-group \
  $(pkg-config --libs libva libva-drm libdrm) -lz -lm -ldl -pthread -o Build/Linux/bin/p0-cpu
