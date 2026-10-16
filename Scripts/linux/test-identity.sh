#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
bundle=$(realpath "${1:?Usage: test-identity.sh <bundle-or-artifact>}")
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
docker run --rm --network none --cpus 1 --memory 1g --pids-limit 128 \
  --cap-drop ALL --security-opt no-new-privileges --read-only \
  --tmpfs /root:rw,mode=700,size=16m --tmpfs /tmp:rw,mode=1777,size=16m \
  --mount "type=bind,src=$bundle,dst=/app,readonly" \
  --mount "type=bind,src=$repo/Linux/tests/app_identity.py,dst=/test.py,readonly" \
  --entrypoint python3 "$image" /test.py
