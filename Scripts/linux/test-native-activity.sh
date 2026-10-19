#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-activity.sh ARTIFACT}")
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) echo 'Expected native artifact under Build/Linux/artifacts' >&2; exit 2;; esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-activity-smoke/$(date -u +%Y%m%dT%H%M%SZ)
# Root only reads the private native Host's observation endpoint. SYS_PTRACE
# permits its exact /proc identity check across UIDs inside this container.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --cap-add SYS_PTRACE --env PYTHONDONTWRITEBYTECODE=1 \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_activity_smoke.py "$output" "$(id -u)" "$(id -g)"
