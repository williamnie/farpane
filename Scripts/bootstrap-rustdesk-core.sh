#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
vendor_dir="$repo_dir/Vendor/rustdesk"
pinned_commit=6c578292e8ebbbec708b76986ba8c4bc7c509747
patch_file="$repo_dir/CoreBridge/RustDeskPatch/upstream-1.4.9.patch"
bridge_source="$repo_dir/CoreBridge/RustDeskPatch/rdn_bridge.rs"

if [[ ! -d "$vendor_dir/.git" ]]; then
  mkdir -p "${vendor_dir:h}"
  git clone --branch 1.4.9 --depth 1 https://github.com/rustdesk/rustdesk.git "$vendor_dir"
  git -C "$vendor_dir" submodule update --init --recursive --depth 1
fi

actual_commit=$(git -C "$vendor_dir" rev-parse HEAD)
if [[ "$actual_commit" != "$pinned_commit" ]]; then
  print -u2 "RustDesk checkout mismatch: expected=$pinned_commit actual=$actual_commit"
  exit 1
fi

if git -C "$vendor_dir" apply --check "$patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$patch_file"
elif ! git -C "$vendor_dir" apply --check --reverse "$patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the Phase 2 patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if [[ -e "$vendor_dir/src/rdn_bridge.rs" ]]; then
  if ! cmp -s "$vendor_dir/src/rdn_bridge.rs" "$bridge_source"; then
    print -u2 "existing src/rdn_bridge.rs differs from the tracked bridge source"
    exit 1
  fi
else
  cp "$bridge_source" "$vendor_dir/src/rdn_bridge.rs"
fi

git -C "$vendor_dir" diff --check
git -C "$vendor_dir" apply --check --reverse "$patch_file"
print "RUSTDESK_CORE_SOURCE_READY commit=$actual_commit"
