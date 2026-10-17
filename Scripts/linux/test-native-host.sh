#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-host-smoke/$(date -u +%Y%m%dT%H%M%SZ)
# Root is confined to the container to assemble an immutable test release.
# No host display/GPU/network/service socket is exposed; child tests run as UID.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_host_smoke.py "$output" "$(id -u)" "$(id -g)"
