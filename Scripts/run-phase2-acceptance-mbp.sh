#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
if [[ "$(uname -m)" != x86_64 ]]; then
  print -u2 "Phase 2 acceptance must run on the Intel MBP"
  exit 2
fi
: "${RDN_PASSWORD:?Set RDN_PASSWORD securely in this MBP shell}"

app="$repo_dir/.build/release/RustDeskNative"
core="$repo_dir/Build/CoreBridge/x86_64/liblibrustdesk.dylib"
preflight_prefix="$repo_dir/Benchmarks/phase2-live-4k-relay-preflight-60s"
acceptance_prefix="$repo_dir/Benchmarks/phase2-live-4k-relay-acceptance-1800s"

[[ -x "$app" ]] || { print -u2 "release executable not found: $app"; exit 2; }
[[ -f "$core" ]] || { print -u2 "Core dylib not found: $core"; exit 2; }

for prefix in "$preflight_prefix" "$acceptance_prefix"; do
  if [[ -e "$prefix.json" || -e "$prefix.samples.csv" || -e "$prefix.log" || -e "$prefix.validation.txt" ]]; then
    print -u2 "refusing to overwrite existing benchmark artifacts for $prefix"
    exit 2
  fi
done

RDN_FORCE_RELAY=1 RDN_PHASE2_4K_PREFLIGHT=1 \
  "$repo_dir/Scripts/benchmark-live-from-rustdesk-config-mbp.sh" \
  "$app" "$core" 60 automatic "$preflight_prefix"

print "4K preflight passed; waiting five seconds for remote session cleanup"
sleep 5

RDN_FORCE_RELAY=1 \
  "$repo_dir/Scripts/benchmark-live-from-rustdesk-config-mbp.sh" \
  "$app" "$core" 1800 automatic "$acceptance_prefix"
