#!/usr/bin/env bash
set -euo pipefail
cd /workspace
source_dir=Build/Linux/src/libdrmtap
build_dir=Build/Linux/drmtap-build
meson_version=$(python3 -c 'import json; print(json.load(open("Linux/dependencies.lock.json"))["meson"]["version"])')
export PYTHONPATH="/workspace/Build/Linux/tools/meson-$meson_version"
meson() { python3 -m mesonbuild.mesonmain "$@"; }
if [[ ! -f "$build_dir/build.ninja" ]]; then
  meson setup "$build_dir" "$source_dir" --buildtype=release -Dhelper=disabled -Degl=enabled
else
  meson configure "$build_dir" -Dhelper=disabled -Degl=enabled
fi
meson compile -C "$build_dir" -j4 drmtap:shared_library
python3 - <<'PY'
from pathlib import Path
import ctypes, hashlib, json, subprocess
lock = json.loads(Path('Linux/dependencies.lock.json').read_text())
assert Path('Build/Linux/src/libdrmtap/.farpane-source-pin').read_text().strip() == lock['libdrmtap']['commit']
files = [p for p in Path('Build/Linux/drmtap-build').glob('libdrmtap.so.0.*') if p.is_file() and not p.is_symlink()]
assert len(files) == 1, files
path = files[0]
library = ctypes.CDLL(str(path.resolve()))
library.drmtap_version.restype = ctypes.c_int
v = library.drmtap_version()
version = '.'.join(str((v >> shift) & 255) for shift in (16, 8, 0))
assert version == lock['libdrmtap']['version'], version
blob = path.read_bytes()
assert b'/usr/libexec/drmtap-helper' not in blob
symbols = subprocess.check_output(['nm', '-D', str(path)], text=True)
assert 'socketpair' not in symbols
for symbol in ('drmtap_grab_desc', 'drmtap_open_render', 'drmtap_convert_dmabuf', 'drmtap_set_output_buffer', 'drmtap_plane_rotation'):
    assert hasattr(library, symbol), symbol
assert b'eglCreateImage' in blob, 'EGL conversion implementation missing'
print(json.dumps({'path': str(path), 'version': version, 'sha256': hashlib.sha256(blob).hexdigest(), 'helper_disabled': True, 'split_api': True}))
PY
