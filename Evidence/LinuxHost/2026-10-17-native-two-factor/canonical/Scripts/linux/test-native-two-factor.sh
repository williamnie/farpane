#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-two-factor.sh ARTIFACT [video|files]}")
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) exit 2;; esac
mode=two-factor
case "${2:-video}" in video) ;; files) mode=two-factor-files;; *) exit 2;; esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_secrets_test"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-two-factor-smoke/$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$output"
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env "FARPANE_NATIVE_TEST_MODE=$mode" \
  --env "FARPANE_TWO_FACTOR_MALFORMED=${FARPANE_TWO_FACTOR_MALFORMED:-0}" \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" -B \
  /workspace/Linux/tests/native_viewer_smoke.py "$output" "$(id -u)" "$(id -g)"
