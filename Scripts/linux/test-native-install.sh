#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
case "${2:-builder}" in
  builder) image_key=native_builder ;;
  ubuntu-24.04) image_key=native_runtime_ubuntu2404 ;;
  *) echo 'Expected builder or ubuntu-24.04' >&2; exit 2 ;;
esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["image"])' "$repo/Linux/dependencies.lock.json" "$image_key")
output=/workspace/Build/Linux/native-install-smoke/$(date -u +%Y%m%dT%H%M%SZ)
extra=()
if [[ -n "${1:-}" ]]; then
  artifact=$(realpath -- "$1")
  case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) echo 'Expected artifact under Build/Linux/artifacts' >&2; exit 2;; esac
  extra+=(--env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}")
fi
if [[ -n "${3:-}" ]]; then
  fixture=$(realpath -- "$3")
  case "$fixture" in "$repo/Build/Linux/native-install-smoke/"*) ;; *) echo 'Expected prior owned test fixture' >&2; exit 2;; esac
  extra+=(--env "FARPANE_INSTALL_TEST_FIXTURE=/workspace/${fixture#"$repo/"}")
elif [[ "$image_key" == native_runtime_ubuntu2404 ]]; then
  echo 'Ubuntu runtime requires the verified process fixture from a completed builder test' >&2; exit 2
fi
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 256 \
  --cap-add SYS_PTRACE --env FARPANE_INSTALL_TEST_ISOLATED=1 --env PYTHONDONTWRITEBYTECODE=1 \
  --tmpfs /opt:rw,exec,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  "${extra[@]}" --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_install_smoke.py "$output" "$(id -u)" "$(id -g)"
