#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
input=${1:?Usage: test-native-multidisplay.sh ARTIFACT|--built}
allocator_check=${FARPANE_MONITOR_ALLOCATOR_CHECK:-0}
[[ "$allocator_check" == 0 || "$allocator_check" == 1 ]] || exit 2
artifact_env=()
if [[ "$input" != --built ]]; then
  artifact=$(realpath -- "$input")
  case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) exit 2;; esac
  artifact_env=(--env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}")
fi
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-multidisplay-smoke/$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$output"
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env FARPANE_NATIVE_TEST_MODE=multidisplay \
  --env "FARPANE_MONITOR_ALLOCATOR_CHECK=$allocator_check" \
  "${artifact_env[@]}" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" -B \
  /workspace/Linux/tests/native_viewer_smoke.py "$output" "$(id -u)" "$(id -g)"
