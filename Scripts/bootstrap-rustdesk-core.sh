#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
vendor_dir="$repo_dir/Vendor/rustdesk"
pinned_commit=6c578292e8ebbbec708b76986ba8c4bc7c509747
patch_file="$repo_dir/CoreBridge/RustDeskPatch/upstream-1.4.9.patch"
rich_text_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-rich-text-transfer.patch"
viewer_image_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-image-api.patch"
hbb_common_patch_file="$repo_dir/CoreBridge/RustDeskPatch/hbb-common-7e1c392.patch"
file_transfer_block_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-bounded-block.patch"
file_transfer_mutation_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-mutation-dispatch.patch"
bridge_source="$repo_dir/CoreBridge/RustDeskPatch/rdn_bridge.rs"
host_bridge_source="$repo_dir/CoreBridge/RustDeskPatch/rdn_host_bridge.rs"
host_file_transfer_source="$repo_dir/CoreBridge/RustDeskPatch/rdn_host_file_transfer.rs"

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
elif git -C "$vendor_dir" apply --check --reverse "$patch_file" 2>/dev/null; then
  :
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$rich_text_patch_file" 2>/dev/null; then
  # The extension overlaps connection.rs, so the base patch alone is no
  # longer reverse-applicable once both layers are present.
  :
else
  print -u2 "RustDesk checkout has changes that do not match the Phase 2 patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$viewer_image_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$viewer_image_patch_file"
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_image_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer image API patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$rich_text_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$rich_text_patch_file"
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$rich_text_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 rich-text transfer patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$file_transfer_mutation_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$file_transfer_mutation_patch_file"
elif ! git -C "$vendor_dir" apply --check --reverse "$file_transfer_mutation_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 file-transfer mutation patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

hbb_common_dir="$vendor_dir/libs/hbb_common"
if git -C "$hbb_common_dir" apply --check "$hbb_common_patch_file" 2>/dev/null; then
  git -C "$hbb_common_dir" apply "$hbb_common_patch_file"
elif ! git -C "$hbb_common_dir" apply --check --reverse "$hbb_common_patch_file" 2>/dev/null; then
  print -u2 "hbb_common checkout has changes that do not match the secret-wipe patch"
  git -C "$hbb_common_dir" status --short >&2
  exit 1
fi

if git -C "$hbb_common_dir" apply --check "$file_transfer_block_patch_file" 2>/dev/null; then
  git -C "$hbb_common_dir" apply "$file_transfer_block_patch_file"
elif ! git -C "$hbb_common_dir" apply --check --reverse "$file_transfer_block_patch_file" 2>/dev/null; then
  print -u2 "hbb_common checkout has changes that do not match the H6 file-transfer block patch"
  git -C "$hbb_common_dir" status --short >&2
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

# The host bridge is wholly owned by this repository; the tracked source is
# authoritative and always synced into the vendor checkout.
cp "$host_bridge_source" "$vendor_dir/src/rdn_host_bridge.rs"
cp "$host_file_transfer_source" "$vendor_dir/src/rdn_host_file_transfer.rs"

git -C "$vendor_dir" diff --check
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$rich_text_patch_file"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_image_patch_file"
git -C "$vendor_dir" apply --check --reverse "$file_transfer_mutation_patch_file"
git -C "$hbb_common_dir" diff --check
git -C "$hbb_common_dir" apply --check --reverse "$hbb_common_patch_file"
git -C "$hbb_common_dir" apply --check --reverse "$file_transfer_block_patch_file"
if ! cmp -s "$vendor_dir/src/rdn_host_file_transfer.rs" "$host_file_transfer_source"; then
  print -u2 "native Host file-transfer root source differs from its canonical source"
  exit 1
fi
print "RUSTDESK_CORE_SOURCE_READY commit=$actual_commit"
