#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
profile=${1:-release}
[[ "$profile" == release || "$profile" == debug ]]
"$repo/Scripts/linux/container.sh" -c "cc Linux/tests/p0_load.c -ldl -o Build/Linux/bin/p0-load && python3 Scripts/linux/stage-load-test.py $profile"
core_hash=$(sha256sum "$repo/Build/Linux/target/$profile/liblibrustdesk.so")
load_root="$repo/Build/Linux/load-root-${core_hash:0:12}"
# SYS_CHROOT/SETUID/SETGID exist only inside this disposable container. The
# loader runs uid 1000 inside an ELF-only root, with no GPU, config or sockets.
exec docker run --rm --network none --cpus 1 --memory 1g --pids-limit 32 \
  --read-only --cap-drop ALL --cap-add SYS_CHROOT --cap-add SETUID --cap-add SETGID \
  --security-opt no-new-privileges \
  --mount "type=bind,src=$load_root,dst=/load-root,readonly" \
  --entrypoint /usr/bin/chroot "$image" --userspec=1000:1000 \
  /load-root /probe/p0-load /probe/liblibrustdesk.so
