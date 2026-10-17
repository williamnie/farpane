#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source=$(realpath -- "${1:?Usage: build-native-source.sh SOURCE_DIR MANIFEST_SHA256 FRESH_DEPENDENCIES_DIR PREFIX_MANIFEST_SHA256 [IMAGE] [VERIFY_COMPLETED_BUILD_DIR]}")
source_hash=${2:?Source manifest SHA256 is required}
dependencies=$(realpath -- "${3:?Fresh native dependencies output directory is required}")
dependencies_hash=${4:?Native dependency inventory SHA256 is required}
image=${5:-farpane-native-source-builder:ubuntu2404}
[[ "$source_hash" =~ ^[0-9a-f]{64}$ && "$dependencies_hash" =~ ^[0-9a-f]{64}$ ]] || exit 2
test -f "$source/source-manifest.json"
test -f "$dependencies/result.json"
test -f "$dependencies/installed-manifest.json"
mkdir -p "$repo/Build/Linux/native-bootstrap"
mode=()
image_id=$(docker image inspect "$image" --format '{{.Id}}')
if [[ -n "${6:-}" ]]; then
  output=$(realpath -- "$6")
  case "$output" in "$repo/Build/Linux/native-bootstrap/application."*) ;; *) exit 2;; esac
  test -f "$output/stages.json"
  [[ "$(cat "$output/builder-image-id.txt")" == "$image_id" ]] || exit 2
  mode=(--verify)
else
  output=$(mktemp -d "$repo/Build/Linux/native-bootstrap/application.XXXXXXXX")
  mkdir "$output/workspace"
  printf '%s\n' "$image_id" > "$output/builder-image-id.txt"
fi
printf '%s\n' "$output"
# The existing FFmpeg/product prefix and Cargo caches are not mounted. Only the
# standard Rust SDK is reused read-only; every application/media output is new.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$source,dst=/inputs/source,readonly" \
  --mount "type=bind,src=$dependencies,dst=/inputs/dependencies,readonly" \
  --mount "type=bind,src=$repo/Build/Linux/toolchain,dst=/toolchain,readonly" \
  --mount "type=bind,src=$repo/Linux/packaging/native_source_build.py,dst=/inputs/build.py,readonly" \
  --mount "type=bind,src=$output,dst=/output" \
  --mount "type=bind,src=$output/workspace,dst=/workspace" \
  --workdir /workspace --entrypoint python3 "$image" -B /inputs/build.py "$source_hash" "$dependencies_hash" "${mode[@]}"
