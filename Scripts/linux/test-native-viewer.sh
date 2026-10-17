#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
output=/workspace/Build/Linux/native-viewer-smoke/$(date -u +%Y%m%dT%H%M%SZ)
mode=${1:-video}
large_clipboard=0
if [[ "$mode" == clipboard-large ]]; then mode=clipboard; large_clipboard=1; fi
case "$mode" in video|recovery|auto-reconnect|approval|desktop|hud|input|clipboard|retry|cursor|audio|secrets|secrets-locked|secrets-boundary|secrets-unavailable|files|files-empty|files-matrix|files-tree|files-tree-fault|files-secrets) ;; *) echo 'Usage: test-native-viewer.sh [video|recovery|auto-reconnect|approval|desktop|hud|input|clipboard|clipboard-large|retry|cursor|audio|secrets|secrets-locked|secrets-boundary|secrets-unavailable|files|files-empty|files-matrix|files-tree|files-tree-fault|files-secrets]' >&2; exit 2;; esac
if [[ "$mode" == audio || "$mode" == secrets-unavailable ]]; then
  image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_audio_test"]["image"])' "$repo/Linux/dependencies.lock.json")
fi
if [[ "$mode" == auto-reconnect || "$mode" == recovery || "$mode" == desktop || "$mode" == secrets || "$mode" == secrets-boundary || "$mode" == secrets-locked || "$mode" == files-secrets ]]; then
  image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_secrets_test"]["image"])' "$repo/Linux/dependencies.lock.json")
fi
# Loopback only, two private X servers, no GPU/host desktop/service/config mounts.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env "FARPANE_NATIVE_TEST_MODE=$mode" \
  --env "FARPANE_CLIPBOARD_LARGE=$large_clipboard" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_viewer_smoke.py "$output" "$(id -u)" "$(id -g)"
