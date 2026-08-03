#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
if [[ "$(uname -m)" != x86_64 ]]; then
  print -u2 "Phase 3 input preflight must run on the Intel MBP"
  exit 2
fi
: "${RDN_PASSWORD:?Set RDN_PASSWORD securely in this MBP shell}"

app="$repo_dir/.build/release/RustDeskNative"
core="$repo_dir/Build/CoreBridge/x86_64/liblibrustdesk.dylib"
prefix="$repo_dir/Benchmarks/phase3-input-fix-preflight-$(date +%Y%m%d-%H%M%S)-180s"

[[ -x "$app" ]] || { print -u2 "release executable not found: $app"; exit 2; }
[[ -f "$core" ]] || { print -u2 "Core dylib not found: $core"; exit 2; }

print "Run the real Hermes input preflight for three minutes."
print "Verify local Chinese IME commit, precise scrolling, held Backspace repeat,"
print "and smooth video while dragging and typing. Disconnect immediately on failure."

RDN_PHASE2_SMOKE=1 RDN_FORCE_RELAY=1 \
  "$repo_dir/Scripts/benchmark-live-from-rustdesk-config-mbp.sh" \
  "$app" "$core" 180 automatic "$prefix"

print "PHASE3_INPUT_PREFLIGHT_PREFIX=$prefix"
