#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
if [[ ! -f /.dockerenv || $repo != /workspace ]]; then
    exec "$repo/Scripts/linux/native-container.sh" Scripts/linux/test-native-renderer.sh
fi
mkdir -p Build/Linux/gui-renderer-test
cc -std=c11 -D_POSIX_C_SOURCE=200809L -O2 -Wall -Wextra -Werror \
    Linux/tests/gpu_renderer_test.c Linux/gui/src/gpu_renderer.c \
    -lEGL -lGLESv2 -lgbm -o Build/Linux/gui-renderer-test/probe
# A CPU-rendered EGL pbuffer: no GPU device, X11, Wayland, or real desktop.
EGL_PLATFORM=surfaceless LIBGL_ALWAYS_SOFTWARE=1 \
    Build/Linux/gui-renderer-test/probe
