#!/bin/zsh
set -euo pipefail

if (( $# != 5 )); then
  print -u2 "usage: $0 APP_OR_EXECUTABLE CORE_DYLIB DURATION GPU OUTPUT_PREFIX"
  print -u2 "set RDN_PASSWORD only in this shell; it is never written to disk"
  exit 2
fi
if [[ "${RDN_VALIDATE_EXISTING:-0}" != 1 ]]; then
  : "${RDN_PASSWORD:?Set RDN_PASSWORD securely in the current MBP shell}"
fi

repo_dir=${0:A:h:h}
export RDN_CONFIG_RUNNER="$repo_dir/Scripts/benchmark-live-mbp.sh"
export RDN_LIVE_APP=$1
export RDN_LIVE_CORE=$2
export RDN_LIVE_DURATION=$3
export RDN_LIVE_GPU=$4
export RDN_LIVE_PREFIX=$5

python3 - <<'PY'
import ast
import os
import sys
import time
from pathlib import Path

root = Path.home() / "Library/Preferences/com.carriez.RustDesk"
server_candidates = []
for path in root.glob("*.toml"):
    fields = {}
    for line in path.read_text(errors="ignore").splitlines():
        if "=" not in line:
            continue
        name, raw = line.split("=", 1)
        name, raw = name.strip(), raw.strip()
        if name not in ("custom-rendezvous-server", "rendezvous_server", "key"):
            continue
        try:
            fields[name] = ast.literal_eval(raw)
        except Exception:
            pass
    candidate = fields.get("custom-rendezvous-server") or fields.get("rendezvous_server")
    if candidate and fields.get("key"):
        server_candidates.append((candidate, fields["key"]))

distinct_servers = set(server_candidates)
if len(distinct_servers) != 1:
    raise SystemExit("RustDesk config must contain one unambiguous Hermes configuration")
server, key = next(iter(distinct_servers))

peer_root = root / "peers"
peers = sorted(
    (
        path
        for path in peer_root.glob("*.toml")
        if "@" not in path.stem and "?" not in path.stem
    ),
    key=lambda path: path.stat().st_mtime,
    reverse=True,
)
explicit_peer = os.environ.get("RDN_PEER_ID", "").strip()
if explicit_peer:
    if Path(explicit_peer).name != explicit_peer:
        raise SystemExit("RDN_PEER_ID must be a profile name, not a path")
    peer = peer_root / f"{explicit_peer}.toml"
    if not peer.is_file():
        raise SystemExit("RDN_PEER_ID does not match an existing RustDesk peer profile")
elif len(peers) == 1:
    peer = peers[0]
elif len(peers) > 1:
    newest_age = time.time() - peers[0].stat().st_mtime
    newest_gap = peers[0].stat().st_mtime - peers[1].stat().st_mtime
    if not (0 <= newest_age <= 900 and newest_gap >= 60):
        raise SystemExit(
            "Multiple RustDesk peer profiles are ambiguous; reconnect the intended peer "
            "once in the original RustDesk app, close that connection, then rerun within 15 minutes"
        )
    peer = peers[0]
    print(
        f"Selected the uniquely recent RustDesk peer profile from {len(peers)} profiles; peer ID is not printed",
        file=sys.stderr,
    )
else:
    raise SystemExit("RustDesk config does not contain a peer profile")

environment = os.environ.copy()
environment["RDN_SERVER"] = server
environment["RDN_SERVER_PUBLIC_KEY"] = key
environment["RDN_PEER_ID"] = peer.stem
command = [
    environment["RDN_CONFIG_RUNNER"],
    environment["RDN_LIVE_APP"],
    environment["RDN_LIVE_CORE"],
    environment["RDN_LIVE_DURATION"],
    environment["RDN_LIVE_GPU"],
    environment["RDN_LIVE_PREFIX"],
]
os.execve(command[0], command, environment)
PY
