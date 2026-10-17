#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
network=none
if [[ "${1:-}" == --fetch ]]; then
  network=bridge
  shift
fi
# Only dependency acquisition opts into networking. No desktop, GPU, host
# service sockets or credentials are mounted, including for GUI smoke tests.
exec docker run --rm --network "$network" --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  -e CARGO_HOME=/workspace/Build/Linux/cargo \
  -e CARGO_TARGET_DIR=/workspace/Build/Linux/native-target \
  -e CARGO_BUILD_JOBS=4 \
  -e PATH=/workspace/Build/Linux/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /workspace --entrypoint bash "$image" "$@"
