#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
archive=$(realpath -- "${1:?Usage: test-native-source-package.sh SOURCE_ARCHIVE ARCHIVE_SHA256 SOURCE_BUILD BUILD_RESULT_SHA256 VERSION [IMAGE]}")
archive_hash=${2:?Source archive SHA256 required}
application=$(realpath -- "${3:?Completed isolated source build directory required}")
result_hash=${4:?Build result SHA256 required}
version=${5:?Debian candidate version required}
image=${6:-farpane-native-source-builder:ubuntu2404}
[[ "$archive_hash" =~ ^[0-9a-f]{64}$ && "$result_hash" =~ ^[0-9a-f]{64}$ ]] || exit 2
mkdir -p "$repo/Build/Linux/native-source-package"
output=$(mktemp -d "$repo/Build/Linux/native-source-package/package.XXXXXXXX")
docker image inspect "$image" --format '{{.Id}}' > "$output/builder-image-id.txt"
printf '%s\n' "$output"
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$archive,dst=/inputs/source.tar.gz,readonly" \
  --mount "type=bind,src=$application,dst=/inputs/application,readonly" \
  --mount "type=bind,src=$repo/Linux/tests/native_source_package_smoke.py,dst=/inputs/test.py,readonly" \
  --mount "type=bind,src=$repo/Linux/packaging/native_source_build.py,dst=/inputs/native_source_build.py,readonly" \
  --mount "type=bind,src=$output,dst=/output" \
  --workdir /output --entrypoint python3 "$image" -B /inputs/test.py "$archive_hash" "$result_hash" "$version"
