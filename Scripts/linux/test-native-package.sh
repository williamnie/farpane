#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
artifact=$(realpath -- "${1:?Usage: test-native-package.sh ARTIFACT [builder|ubuntu-24.04]}")
case "$artifact" in "$repo/Build/Linux/artifacts/"*) ;; *) echo 'Artifact must be under Build/Linux/artifacts' >&2; exit 2;; esac
case "${2:-builder}" in
  builder) image_key=native_builder ;;
  ubuntu-24.04) image_key=native_runtime_ubuntu2404 ;;
  *) echo 'Expected builder or ubuntu-24.04 runtime' >&2; exit 2 ;;
esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["image"])' "$repo/Linux/dependencies.lock.json" "$image_key")
image=${FARPANE_NATIVE_RUNTIME_IMAGE:-$image}
output=/workspace/Build/Linux/native-package-smoke/$(date -u +%Y%m%dT%H%M%SZ)
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env "FARPANE_NATIVE_TEST_ARTIFACT=/workspace/${artifact#"$repo/"}" \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_package_smoke.py "$output" "$(id -u)" "$(id -g)"
