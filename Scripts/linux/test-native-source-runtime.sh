#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
application=$(realpath -- "${1:?Usage: test-native-source-runtime.sh APPLICATION_BUILD_DIRECTORY [IMAGE]}")
image=${2:-farpane-native-source-builder:ubuntu2404}
case "$application" in "$repo/Build/Linux/native-bootstrap/application."*) ;; *) echo 'Expected an isolated source build' >&2; exit 2;; esac
python3 -B - "$application" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);report=json.loads((root/'result.json').read_text())
assert report['result']=='pass' and report['full_native_media_core_gui_build'] is True
build=root/'workspace/Build/Linux'
for component,name in [('native-core','farpane-core'),('native-gui','farpane')]:
    with (build/'source-target/release'/name).open('rb') as stream:
        assert hashlib.file_digest(stream,'sha256').hexdigest()==report['binaries'][component]
library=[p for p in (build/'drmtap-build').glob('libdrmtap.so.0.*') if p.is_file() and not p.is_symlink()]
assert len(library)==1
with library[0].open('rb') as stream:
    assert hashlib.file_digest(stream,'sha256').hexdigest()==report['drmtap_sha256']
# Reuse the existing connection harness without changing its product defaults.
# These aliases exist only in this generated workspace, never the main build.
for name in ['target','native-target']:
    path=build/name
    if path.is_symlink():assert path.readlink()==Path('source-target')
    else:
        assert not path.exists()
        path.symlink_to('source-target',target_is_directory=True)
PY
output=$(mktemp -d "$application/runtime.XXXXXXXX")
docker image inspect "$image" --format '{{.Id}}' > "$output/runtime-image-id.txt"
printf '%s\n' "$output"
# Only loopback and two private X servers inside the container. The host's
# desktop, services, identities, audio and render nodes are inaccessible.
exec docker run --rm --network none --cpus 4 --memory 12g --pids-limit 512 \
  --env FARPANE_NATIVE_TEST_MODE=video \
  --tmpfs /opt:rw,exec,mode=755 --tmpfs /run/farpane-native-test:rw,mode=755 \
  --mount "type=bind,src=$application/workspace,dst=/workspace,readonly" \
  --mount "type=bind,src=$output,dst=/output" \
  --workdir /workspace --entrypoint python3 "$image" -B \
  /workspace/Linux/tests/native_viewer_smoke.py /output/run "$(id -u)" "$(id -g)"
