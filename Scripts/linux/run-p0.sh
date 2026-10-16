#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["builder"]["image"])' "$repo/Linux/dependencies.lock.json")
case "${1:-gpu}" in
  adapter) probe=gpu-adapter ;;
  screenshot) probe=gpu-screenshot ;;
  gpu|gpu-lifecycle|gpu-argb|gpu-pool-one|gpu-steady) probe=p0-media ;;
  cpu|cpu-short) probe=p0-cpu ;;
  legacy-short) probe=p0-cpu-legacy ;;
  *) echo 'Usage: run-p0.sh [adapter|screenshot|gpu|gpu-lifecycle|gpu-argb|gpu-pool-one|gpu-steady|cpu|cpu-short|legacy-short]' >&2; exit 2 ;;
esac
# Only one synthetic render-node probe. No card node, desktop/session bus,
# host HOME, network, IPC/service socket, privileges or mutable repo mount.
exec 9>"$repo/Build/Linux/.gpu-test.lock"
flock -n 9
args=()
case "${1:-gpu}" in
  screenshot) args+=(common::linux_gpu::tests::implicit_tiled_screenshot_uses_driver_detile --exact --ignored --nocapture --test-threads=1) ;;
  gpu-steady) args+=(--steady) ;;
  gpu-lifecycle) args+=(--lifecycle) ;;
  gpu-argb) args+=(--argb) ;;
  gpu-pool-one) args+=(--pool-one) ;;
esac
[[ "${1:-gpu}" != *-short ]] || args+=(--short-gop)
exec docker run --rm --network none --cpus 1 --memory 1g --pids-limit 128 \
  --user "$(id -u):$(id -g)" --group-add "$(stat -c %g /dev/dri/renderD128)" \
  --device /dev/dri/renderD128:/dev/dri/renderD128:rw \
  --cap-drop ALL --security-opt no-new-privileges --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,size=64m \
  --mount "type=bind,src=$repo/Build/Linux/bin,dst=/probe,readonly" \
  -e LIBVA_DRIVER_NAME=radeonsi -e MESA_SHADER_CACHE_DISABLE=true \
  --entrypoint "/probe/$probe" "$image" "${args[@]}"
