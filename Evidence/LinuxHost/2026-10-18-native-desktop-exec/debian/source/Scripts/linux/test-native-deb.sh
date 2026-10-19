#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
first=$(realpath -- "${1:?Usage: test-native-deb.sh FIRST_DEB UPGRADE_DEB [builder|ubuntu-24.04|debian-13]}")
upgrade=$(realpath -- "${2:?Specify the upgrade package}")
for package in "$first" "$upgrade"; do
  case "$package" in "$repo/Build/Linux/debian/"*.deb) ;; *) echo 'Debian inputs must be under Build/Linux/debian' >&2; exit 2;; esac
done
image_lock="$repo/Linux/dependencies.lock.json"
case "${3:-builder}" in
  builder) image_key=native_builder ;;
  ubuntu-24.04) image_key=native_runtime_ubuntu2404 ;;
  debian-13) image_key=debian13; image_lock="$repo/Linux/tests/native-runtime-images.lock.json" ;;
  *) echo 'Expected builder, ubuntu-24.04 or debian-13 runtime' >&2; exit 2 ;;
esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["image"])' "$image_lock" "$image_key")
image=${FARPANE_NATIVE_RUNTIME_IMAGE:-$image}
output=/workspace/Build/Linux/native-deb-smoke/$(date -u +%Y%m%dT%H%M%SZ)
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --workdir /workspace --entrypoint python3 "$image" \
  /workspace/Linux/tests/native_deb_smoke.py "$output" "$(id -u)" "$(id -g)" \
  "/workspace/${first#"$repo/"}" "/workspace/${upgrade#"$repo/"}"
