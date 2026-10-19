#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-coexistence.sh ARTIFACT [run|calibrate|gui-bus]}")
mode=${2:-run}
[[ "$mode" == run || "$mode" == calibrate || "$mode" == gui-bus ]] || exit 2
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) exit 2;; esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-coexistence-smoke/$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$output"
cpus=4
memory=12g
if [[ "$mode" == gui-bus ]]; then cpus=2; memory=4g; fi
exec docker run --rm --init --network none --cpus "$cpus" --memory "$memory" --pids-limit 512 \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --env "FARPANE_COEXIST_MODE=$mode" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint timeout "$image" --kill-after=10 300 python3 -B \
  /workspace/Linux/tests/native_coexistence_smoke.py "$output" "$(id -u)" "$(id -g)"
