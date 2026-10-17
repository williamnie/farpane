#!/usr/bin/env bash
set -euo pipefail
cd /workspace
prefix=/workspace/Build/Linux/vcpkg/installed/x64-linux
mkdir -p Build/Linux/bin Build/Linux/gui-renderer-test
cc -std=c11 -O2 -Wall -Wextra -Werror -c Linux/gui/src/gpu_renderer.c -o Build/Linux/gui-renderer-test/renderer.o
g++ -std=c++17 -O2 -Wall -Wextra -Werror \
  Linux/tests/native_gpu_viewer.cpp Linux/src/viewer_decode.cpp Build/Linux/gui-renderer-test/renderer.o \
  -I"$prefix/include" $(pkg-config --cflags libdrm gbm) \
  -Wl,--start-group "$prefix/lib/libavcodec.a" "$prefix/lib/libavutil.a" \
  "$prefix/lib/libyuv.a" "$prefix/lib/libvpx.a" -Wl,--end-group \
  $(pkg-config --libs libva libva-drm libdrm gbm) -lEGL -lGLESv2 -lz -lm -ldl -pthread \
  -o Build/Linux/bin/native-gpu-viewer
