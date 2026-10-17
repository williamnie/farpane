#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mode=${1:-supported}
case "$mode" in supported) key=native_clipboard_test ;; unavailable) key=native_display_test ;; *) exit 2 ;; esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["image"])' "$repo/Linux/dependencies.lock.json" "$key")
# Private compositor with CPU rendering, no host sockets, devices or network.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  -e CARGO_HOME=/workspace/Build/Linux/cargo -e CARGO_TARGET_DIR=/workspace/Build/Linux/target \
  -e VCPKG_ROOT=/workspace/Build/Linux/vcpkg -e CARGO_BUILD_JOBS=4 -e CXXFLAGS='-include cstdint' \
  -e PATH=/workspace/Build/Linux/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /workspace --entrypoint python3 "$image" /workspace/Linux/tests/native_wayland_clipboard_smoke.py "$mode"
