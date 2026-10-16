#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
bundle=$(realpath -- "${1:?bundle directory required}")
image=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["gui_test"]["image"])' "$repo/Linux/dependencies.lock.json")
output=$(mktemp -d "$repo/Build/Linux/gui-smoke.XXXXXX")
echo "GUI smoke evidence: $output"
docker run --rm --network none --cpus 4 --memory 4g --pids-limit 256 \
  --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
  --read-only --tmpfs /tmp:rw,mode=1777,size=256m \
  --tmpfs "/root:rw,uid=$(id -u),gid=$(id -g),mode=700,size=64m" \
  --mount "type=bind,src=$bundle,dst=/app,readonly" \
  --mount "type=bind,src=$output,dst=/evidence" \
  --mount "type=bind,src=$repo/Linux/tests/gui_settings.py,dst=/test-gui-settings.py,readonly" \
  -e DISPLAY=:99 -e GDK_BACKEND=x11 -e XDG_SESSION_TYPE=x11 \
  -e XDG_CONFIG_HOME=/tmp/config -e XDG_DATA_HOME=/tmp/data \
  -e XDG_RUNTIME_DIR=/tmp/runtime -e LIBGL_ALWAYS_SOFTWARE=1 \
  --entrypoint bash "$image" -c '
    set -euo pipefail
    mkdir -m700 /tmp/runtime
    /app/farpane --farpane-paths > /evidence/paths.json
    python3 - <<'\''PY'\''
import json
from pathlib import Path
p=json.load(open("/evidence/paths.json"))
assert p["app_name"] == "FarPane"
assert p["config_file"] == "/tmp/config/farpane/FarPane.toml"
assert p["main_ipc"].startswith("/tmp/FarPane-")
assert p["service_ipc"] == "/tmp/FarPane-service/ipc_service"
assert p["dbus_name"] == "org.farpane.FarPane"
assert p["gpu_media_enabled_by_default"] is False
if Path("/app/manifest.json").exists():
    assert p.get("gpu_media_compiled", False) == json.load(open("/app/manifest.json"))["gpu_integrated"]
PY
    test ! -d /tmp/config
    Xvfb :99 -screen 0 1024x768x24 -nolisten tcp > /evidence/xvfb.log 2>&1 &
    display_pid=$!
    trap '\''kill "$display_pid" 2>/dev/null || true'\'' EXIT
    for attempt in {1..40}; do
      if xdpyinfo >/dev/null 2>&1; then break; fi
      sleep 0.25
    done
    dbus-run-session -- bash -c '\''
      set -euo pipefail
      /app/farpane --no-server > /evidence/app.log 2>&1 &
      app_pid=$!
      trap "kill $app_pid 2>/dev/null || true" EXIT
      for attempt in {1..40}; do
        kill -0 "$app_pid"
        xwininfo -root -tree > /evidence/windows.txt
        if grep -q "FarPane" /evidence/windows.txt; then break; fi
        sleep 0.5
      done
      grep "FarPane" /evidence/windows.txt
      sleep 5
      kill -0 "$app_pid"
      xwd -root -silent -out /evidence/screen.xwd
      python3 /test-gui-settings.py
      test ! -d /tmp/config/rustdesk
      test ! -d /tmp/RustDesk-service
      cp /gui-test-packages.txt /evidence/packages.txt
    '\''
  '
echo "PASS: isolated FarPane identity and desktop window; screenshot needs visual review"
