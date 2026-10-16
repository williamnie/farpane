#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
reference=$(realpath -- "${1:?reference cache directory required}")
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
build="$repo/Build/Linux"
mkdir -p "$build"
[[ ! -f "$build/.compiler-cache-ready" ]] || exit 0
docker run --rm --network none --cpus 4 --memory 12g --pids-limit 128 \
  --mount "type=bind,src=$reference,dst=/reference,readonly" \
  --mount "type=bind,src=$build,dst=/output" \
  --entrypoint bash "$image" -c '
    set -euo pipefail
    mkdir -p /output/cargo /output/vcpkg/installed /output/toolchain
    for name in git registry; do
      mkdir -p "/output/cargo/$name"
      cp -R --reflink=auto "/reference/cache/cargo/$name/." "/output/cargo/$name/"
    done
    cp -R --reflink=auto /reference/vcpkg/installed/x64-linux /output/vcpkg/installed/
    cp -R --reflink=auto /root/.rustup/toolchains/1.89.0-x86_64-unknown-linux-gnu/. /output/toolchain/
    chown -R "$1:$2" /output/cargo /output/vcpkg /output/toolchain
    chmod -R u+rwX /output/cargo /output/vcpkg /output/toolchain
  ' bash "$(id -u)" "$(id -g)"
touch "$build/.compiler-cache-ready"
