#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
archive=$(realpath -- "${1:?Usage: test-native-source.sh SOURCE.tar.gz SHA256}")
checksum=${2:?Expected archive SHA256 is required}
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid SHA256' >&2; exit 2; }
case "$archive" in "$repo/Build/Linux/source-bundles/"*.tar.gz) ;; *) echo 'Expected a generated source snapshot archive' >&2; exit 2;; esac
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["native_builder"]["image"])' "$repo/Linux/dependencies.lock.json")
image=${FARPANE_NATIVE_BUILDER_IMAGE:-$image}
sdk=$(realpath -- "${FARPANE_NATIVE_RUST_SDK:-$repo/Build/Linux/toolchain}")
test -x "$sdk/bin/rustc" && test -x "$sdk/bin/cargo"
output="$repo/Build/Linux/native-source-smoke/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$output"
# No workspace or Cargo/compiler target cache mounts: only the archive,
# isolated test driver, read-only Rust SDK and fresh output directory.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$archive,dst=/inputs/source.tar.gz,readonly" \
  --mount "type=bind,src=$repo/Linux/tests/native_source_smoke.py,dst=/inputs/test.py,readonly" \
  --mount "type=bind,src=$sdk,dst=/toolchain,readonly" \
  --mount "type=bind,src=$output,dst=/output" \
  --env CARGO_HOME=/output/cargo-home --env CARGO_TARGET_DIR=/output/target --env CARGO_BUILD_JOBS=4 \
  --env PATH=/toolchain/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /output --entrypoint python3 "$image" -B /inputs/test.py "$checksum"
