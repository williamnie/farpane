#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
reference=$(realpath -- "${1:?read-only reference cache required}")
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
# The fixed image owns its generator/Flutter installation as root. Only the
# disposable Build tree is writable; no host HOME or service sockets are mounted.
docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  --mount "type=bind,src=$reference/cache/pub,dst=/reference-pub,readonly" \
  -e PUB_CACHE=/workspace/Build/Linux/pub \
  -e CARGO_HOME=/workspace/Build/Linux/cargo \
  -e CARGO_TARGET_DIR=/workspace/Build/Linux/target \
  -e CARGO_NET_OFFLINE=true -e CARGO_BUILD_JOBS=4 -e CI=true \
  -e PATH=/workspace/Build/Linux/toolchain/bin:/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /workspace/Build/Linux/src/rustdesk --entrypoint bash "$image" -c '
    set -euo pipefail
    trap '\''chown -R "$1:$2" /workspace/Build/Linux/pub /workspace/Build/Linux/src/rustdesk/flutter /workspace/Build/Linux/src/rustdesk/src/bridge_generated* 2>/dev/null || true'\'' EXIT
    if [[ ! -f /workspace/Build/Linux/.pub-cache-ready ]]; then
      mkdir -p "$PUB_CACHE"
      for name in hosted hosted-hashes git; do
        if [[ -d /reference-pub/$name ]]; then
          cp -R --reflink=auto "/reference-pub/$name" "$PUB_CACHE/"
        fi
      done
      touch /workspace/Build/Linux/.pub-cache-ready
    fi
    /root/.cargo/bin/flutter_rust_bridge_codegen --version
    cp /workspace/Linux/flutter-pubspec.lock flutter/pubspec.lock
    (cd flutter && flutter pub get --offline --enforce-lockfile)
    /root/.cargo/bin/flutter_rust_bridge_codegen \
      --rust-input src/flutter_ffi.rs --dart-output flutter/lib/generated_bridge.dart \
      --c-output /workspace/Build/Linux/bridge_generated.h \
      --skip-add-mod-to-lib --no-build-runner --skip-deps-check
    test -s src/bridge_generated.rs
    test -s src/bridge_generated.io.rs
  ' bash "$(id -u)" "$(id -g)"
