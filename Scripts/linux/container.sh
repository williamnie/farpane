#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
# No host network, display, service socket, /usr mount, or GPU by default.
# All writable state belongs to this checkout's ignored Build/Linux directory.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  -e CARGO_HOME=/workspace/Build/Linux/cargo \
  -e CARGO_TARGET_DIR=/workspace/Build/Linux/target \
  -e VCPKG_ROOT=/workspace/Build/Linux/vcpkg \
  -e CARGO_BUILD_JOBS=4 -e CXXFLAGS='-include cstdint' \
  -e PATH=/workspace/Build/Linux/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /workspace --entrypoint bash "$image" "$@"
