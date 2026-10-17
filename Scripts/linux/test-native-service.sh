#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
extra=()
if [[ -n "${1:-}" ]]; then
  artifact=$(realpath -- "$1")
  case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) echo 'Expected native artifact under Build/Linux/artifacts' >&2; exit 2;; esac
  extra+=(--env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}")
fi
output=/workspace/Build/Linux/native-service-smoke/$(date -u +%Y%m%dT%H%M%SZ)
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --cap-add SYS_PTRACE --env FARPANE_SERVICE_TEST_ISOLATED=1 --env PYTHONDONTWRITEBYTECODE=1 \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --mount "type=bind,src=$repo/Linux/tests/native_service_loginctl.py,dst=/usr/bin/loginctl,readonly" \
  "${extra[@]}" --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_service_smoke.py "$output" "$(id -u)" "$(id -g)"
