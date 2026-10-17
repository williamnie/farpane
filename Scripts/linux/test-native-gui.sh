#!/usr/bin/env bash
set -euo pipefail
cd /workspace
profile=${1:-debug}
case "$profile" in debug|release) ;; *) exit 2 ;; esac
variant=${2:-standard}
case "$variant" in
  standard) unset GDK_DISABLE ;;
  no-graphics) export GDK_DISABLE=gl,vulkan ;;
  *) echo 'Unknown smoke variant' >&2; exit 2 ;;
esac
output=/workspace/Build/Linux/native-smoke/$profile/$variant
mkdir -p "$output"
runtime=$(mktemp -d /tmp/farpane-native-runtime.XXXXXX)
trap 'rm -rf "$runtime"' EXIT
export XDG_RUNTIME_DIR="$runtime"
export XDG_CONFIG_HOME="$runtime/config"
export XDG_DATA_HOME="$runtime/data"
export XDG_CACHE_HOME="$runtime/cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
export GSK_RENDERER=cairo
export GTK_A11Y=none
export FARPANE_SMOKE_EXIT_SECONDS=6
export FARPANE_SMOKE_REPORT_DIR="$output"
# Xvfb, session bus and configuration are private to this ephemeral container.
# No host display, service socket, config, GPU or network is available.
dbus-run-session -- xvfb-run -a -s '-screen 0 1280x900x24' \
  /workspace/Build/Linux/native-target/$profile/farpane > "$output/gui.log" 2>&1
python3 - "$output" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for index in range(3):
    image = root / f'page-{index}.png'
    assert image.read_bytes().startswith(b'\x89PNG'), f'missing screenshot: {image}'
    maps = (root / f'page-{index}-maps.txt').read_text().lower()
    for forbidden in ('libgtk-3', 'libgdk-3', 'libflutter', 'libsciter', 'libappindicator'):
        assert forbidden not in maps, f'legacy library loaded: {forbidden}'
    memory = (root / f'page-{index}-memory.txt').read_text()
    pss = next(line for line in memory.splitlines() if line.startswith('Pss:'))
    print(f'page {index}: {pss}')
log = (root / 'gui.log').read_text()
assert 'CRITICAL' not in log and 'smoke capture failed' not in log, log
print('PASS: three native pages rendered, no legacy GUI libraries loaded')
print('This isolated software-renderer smoke is not a hardware memory acceptance test.')
PY
