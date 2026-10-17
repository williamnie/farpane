#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-desktop-bus.sh ARTIFACT}")
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) exit 2;; esac
image=$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_secrets_test"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-desktop-bus-smoke/$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$output"
# Only synthetic X servers, private bus sockets and loopback inside this container.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env FARPANE_NATIVE_TEST_MODE=desktop-bus \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint timeout "$image" --signal=TERM --kill-after=10 210 \
  python3 -B /workspace/Linux/tests/native_viewer_smoke.py "$output" "$(id -u)" "$(id -g)"
