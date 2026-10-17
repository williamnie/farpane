#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
source=$(realpath -- "${1:?Usage: build-native-dependencies.sh VERIFIED_SOURCE_DIR MANIFEST_SHA256 VCPKG_BINARY CMAKE_ARCHIVE [IMAGE]}")
checksum=${2:?Verified source manifest SHA256 is required}
tool=$(realpath -- "${3:?Pinned vcpkg executable is required}")
cmake_archive=$(realpath -- "${4:?Pinned CMake archive is required}")
image=${5:-farpane-native-source-builder:ubuntu2404}
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid SHA256' >&2; exit 2; }
test -f "$source/source-manifest.json"
test -f "$tool"
test -f "$cmake_archive"
mkdir -p "$repo/Build/Linux/native-bootstrap"
output=$(mktemp -d "$repo/Build/Linux/native-bootstrap/dependencies.XXXXXXXX")
docker image inspect "$image" --format '{{.Id}}' > "$output/builder-image-id.txt"
printf '%s\n' "$output"
# No old prefix/compiler cache, host services, credentials, display or render
# device is accessible. Networking is only used to prepare the builder image.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$source,dst=/inputs/source,readonly" \
  --mount "type=bind,src=$tool,dst=/inputs/vcpkg,readonly" \
  --mount "type=bind,src=$cmake_archive,dst=/inputs/cmake.tar.gz,readonly" \
  --mount "type=bind,src=$repo/Linux/packaging/native_bootstrap.py,dst=/inputs/build.py,readonly" \
  --mount "type=bind,src=$repo/Linux/packaging/native-triplets/x64-linux.cmake,dst=/inputs/x64-linux.cmake,readonly" \
  --mount "type=bind,src=$repo/Linux/tests/native_dependencies_probe.cpp,dst=/inputs/probe.cpp,readonly" \
  --mount "type=bind,src=$output,dst=/output" \
  --workdir /output --entrypoint python3 "$image" -B /inputs/build.py "$checksum"
