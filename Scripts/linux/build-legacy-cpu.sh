#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
reference=$(realpath -- "${1:?read-only reference required}")
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
docker run --rm --network none --cpus 4 --memory 12g --pids-limit 128 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --mount "type=bind,src=$reference,dst=/reference,readonly" \
  --workdir /workspace --entrypoint bash "$image" -c '
    set -euo pipefail
    pin=$(python3 -c '\''import json;print(json.load(open("Linux/dependencies.lock.json"))["hwcodec"]["commit"])'\'')
    sources=(/reference/cache/cargo/git/checkouts/hwcodec-*/"${pin:0:7}")
    [[ ${#sources[@]} == 1 ]]
    hw=/workspace/Build/Linux/legacy-hwcodec
    mkdir -p "$hw"
    git -c "safe.directory=${sources[0]}" -C "${sources[0]}" archive "$pin" | tar -x -C "$hw"
    prefix=/reference/vcpkg/installed/x64-linux
    g++ -std=c++17 -O2 -include cstdint -DEXPECTED_FFMPEG=\"7.1.1\" Linux/tests/p0_cpu.cpp \
      "$hw/cpp/ffmpeg_ram/ffmpeg_ram_encode.cpp" "$hw/cpp/ffmpeg_ram/ffmpeg_ram_decode.cpp" \
      "$hw/cpp/common/util.cpp" "$hw/cpp/common/log.cpp" "$hw/cpp/common/platform/linux/linux.cpp" \
      "$hw/cpp/mux/mux.cpp" -I"$hw/cpp/common" -I"$hw/cpp/common/platform/linux" \
      -I"$hw/cpp/ffmpeg_ram" -I"$hw/cpp/mux" \
      -IBuild/Linux/src/hwcodec/externals/nv-codec-headers_n12.1.14.0/include/ffnvcodec -I"$prefix/include" \
      -Wl,--start-group "$prefix/lib/libavformat.a" "$prefix/lib/libavcodec.a" \
      "$prefix/lib/libavutil.a" "$prefix/lib/libyuv.a" -Wl,--end-group \
      -lva -lva-drm -lva-x11 -lX11 -ldrm -lz -lm -ldl -pthread -o Build/Linux/bin/p0-cpu-legacy
  '
