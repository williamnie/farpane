#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
docker run --rm --network none --cpus 2 --memory 4g --pids-limit 512 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  -e PUB_CACHE=/workspace/Build/Linux/pub -e CI=true \
  -e PATH=/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /workspace/Build/Linux/src/rustdesk/flutter --entrypoint bash "$image" -c '
    set -euo pipefail
    trap '\''chown -R "$1:$2" /workspace/Build/Linux/src/rustdesk/flutter /workspace/Build/Linux/pub'\'' EXIT
    flutter test --no-pub --concurrency=2 --reporter=expanded
  ' bash "$(id -u)" "$(id -g)"
