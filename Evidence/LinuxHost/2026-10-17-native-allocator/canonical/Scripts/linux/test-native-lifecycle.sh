#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-lifecycle.sh ARTIFACT [1|20] [calibrate|objects]}")
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) exit 2;; esac
rounds=${2:-20}
[[ "$rounds" == 1 || "$rounds" == 20 ]] || exit 2
calibrate=0
objects=0
case "${3:-}" in calibrate) calibrate=1;; objects) objects=1;; '') ;; *) exit 2;; esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-lifecycle-smoke/$(date -u +%Y%m%dT%H%M%SZ)
printf '%s\n' "$output"
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env FARPANE_NATIVE_TEST_MODE=lifecycle \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --env "FARPANE_LIFECYCLE_ROUNDS=$rounds" --env "FARPANE_LIFECYCLE_CALIBRATE=$calibrate" \
  --env "FARPANE_LIFECYCLE_OBJECTS=$objects" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" -B \
  /workspace/Linux/tests/native_viewer_smoke.py "$output" "$(id -u)" "$(id -g)"
