#!/usr/bin/env bash
set -euo pipefail
cd /workspace
prefix=/workspace/Build/Linux/vcpkg/installed/x64-linux
g++ -std=c++17 -O2 -Wall -Wextra -Werror Linux/tests/gpu_adapter.cpp Linux/src/gpu_media.cpp \
  -I"$prefix/include" $(pkg-config --cflags libdrm libdrm_amdgpu) \
  -Wl,--start-group "$prefix/lib/libavfilter.a" "$prefix/lib/libavcodec.a" \
  "$prefix/lib/libavutil.a" "$prefix/lib/libyuv.a" -Wl,--end-group \
  $(pkg-config --libs libva libva-drm libdrm libdrm_amdgpu gbm) -lz -lm -ldl -pthread \
  -o Build/Linux/bin/gpu-adapter
