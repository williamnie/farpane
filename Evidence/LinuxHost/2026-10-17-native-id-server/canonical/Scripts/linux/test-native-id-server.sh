#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-id-server.sh ARTIFACT}")
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) exit 2;; esac
python3 -B "$repo/Scripts/linux/prepare-native-id-server.py"
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-id-server-smoke/$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$output"
exec docker run --rm --network none --cap-add NET_ADMIN --cpus 4 --memory 12g --pids-limit 512 \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" -B \
  /workspace/Linux/tests/native_id_server_smoke.py --setup-isolated-address "$output"
