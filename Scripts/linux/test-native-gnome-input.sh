#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["native_gnome_input_test"]["image"])' "$repo/Linux/dependencies.lock.json")
mode=${2:-entry}
case "$mode" in entry|terminal|browser) ;; *) echo 'Expected entry, terminal or browser fixture' >&2; exit 2;; esac
output=/workspace/Build/Linux/native-gnome-input-smoke/$(date -u +%Y%m%dT%H%M%SZ)-$mode
extra=()
browser_mount=()
if [[ "$mode" == browser ]]; then
  chrome=$(realpath -- "${FARPANE_TEST_CHROME_DIR:-/opt/google/chrome}")
  test -x "$chrome/chrome"
  browser_mount=(--mount "type=bind,src=$chrome,dst=/opt/farpane-test-chrome,readonly")
  export FARPANE_GNOME_INPUT_SEED=0
fi
if [[ -n "${1:-}" ]]; then
  binary=$(realpath -- "$1")
  case "$binary" in "$repo/Build/Linux/target/"*) ;; *) echo 'Expected owned native test binary' >&2; exit 2;; esac
  extra+=("/workspace/${binary#"$repo/"}")
fi
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  -e FARPANE_GNOME_INPUT_TARGET="$mode" \
  -e FARPANE_GNOME_INPUT_TEST="${FARPANE_GNOME_INPUT_TEST:-server::input_service::native_paste_tests::private_mutter_production_paste}" \
  -e FARPANE_GNOME_INPUT_SEED="${FARPANE_GNOME_INPUT_SEED:-0}" \
  --user "$(id -u):$(id -g)" --security-opt no-new-privileges \
  --tmpfs /run/farpane-native-test:rw,mode=777 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  "${browser_mount[@]}" \
  --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_gnome_input_smoke.py "$output" "${extra[@]}"
