#!/usr/bin/env bash
set -euo pipefail
cd /workspace
# The GPU build includes the module; its runtime option still defaults off.
case "${1:-b0}" in
  b0) features=flutter,hwcodec,drm ;;
  farpane) features=flutter,hwcodec,drm,farpane-linux ;;
  gpu) features=flutter,hwcodec,drm,farpane-linux,linux-gpu-media ;;
  *) echo 'Usage: build-core.sh [b0|farpane|gpu]' >&2; exit 2 ;;
esac
python3 - <<'PY'
from pathlib import Path
import hashlib, json
lock=json.loads(Path('Linux/dependencies.lock.json').read_text())
entry=next(e for e in lock['lockfiles'] if e['path']=='Linux/Cargo.lock')
for path in ('Linux/Cargo.lock','Build/Linux/src/rustdesk/Cargo.lock'):
    if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=entry['sha256']:
        raise SystemExit('Cargo lock mismatch: '+path)
PY
cd Build/Linux/src/rustdesk
cargo build --offline --locked --release --lib --features "$features"
python3 - "$features" <<'PY'
from pathlib import Path
import hashlib, json, sys
build = Path('/workspace/Build/Linux')
(build / 'core-build.json').write_text(json.dumps({
    'features': sys.argv[1].split(','),
    'core_sha256': hashlib.sha256((build / 'target/release/liblibrustdesk.so').read_bytes()).hexdigest(),
}, indent=2) + '\n')
PY
