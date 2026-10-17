#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
snapshot=$(realpath -- "${1:?Usage: test-native-notice-delivery.sh SOURCE_SNAPSHOT}")
case "$snapshot" in "$repo/Build/Linux/source-bundles/farpane-native-source-"*) ;; *) exit 2;; esac
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output="$repo/Build/Linux/native-notice-delivery-smoke/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p -- "$output"
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 128 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$snapshot,dst=/source,readonly" \
  --mount "type=bind,src=$output,dst=/output" \
  --workdir /source --entrypoint python3 "$image" -B \
  /source/Linux/tests/native_notice_delivery_smoke.py /output
