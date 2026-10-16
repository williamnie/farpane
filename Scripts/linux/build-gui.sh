#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
test -s "$repo/Build/Linux/target/release/liblibrustdesk.so"
test -s "$repo/Build/Linux/src/rustdesk/flutter/lib/generated_bridge.dart"
docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --mount "type=bind,src=$repo,dst=/workspace,readonly" \
  --mount "type=bind,src=$repo/Build/Linux,dst=/workspace/Build/Linux" \
  -e PUB_CACHE=/workspace/Build/Linux/pub \
  -e CARGO_TARGET_DIR=/workspace/Build/Linux/target \
  -e CMAKE_BUILD_PARALLEL_LEVEL=4 -e CI=true \
  -e PATH=/workspace/Linux/build-support:/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --workdir /workspace/Build/Linux/src/rustdesk/flutter --entrypoint bash "$image" -c '
    set -euo pipefail
    trap '\''chown -R "$1:$2" /workspace/Build/Linux/src/rustdesk/flutter /workspace/Build/Linux/pub'\'' EXIT
    python3 - <<'\''PY'\''
from pathlib import Path
import hashlib, json
root = Path("/workspace")
lock = json.loads((root / "Linux/dependencies.lock.json").read_text())
entry = next(e for e in lock["lockfiles"] if e["path"] == "Linux/flutter-pubspec.lock")
for path in (root / entry["path"], Path("pubspec.lock")):
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit("Flutter lock mismatch: " + str(path))
PY
    flutter --version
    flutter pub get --offline --enforce-lockfile
    dart run build_runner build
    flutter build linux --release --no-pub
    cmp /workspace/Build/Linux/target/release/liblibrustdesk.so build/linux/x64/release/bundle/lib/librustdesk.so
  ' bash "$(id -u)" "$(id -g)"
