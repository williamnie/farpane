#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
vendor_dir="$repo_dir/Vendor/rustdesk"
hbb_common_dir="$vendor_dir/libs/hbb_common"
pinned_commit=6c578292e8ebbbec708b76986ba8c4bc7c509747

viewer_file_receive_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-file-receive-interception.patch"
viewer_file_digest_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-file-digest-confirmation.patch"
viewer_file_upload_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-file-upload-wire.patch"
native_read_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-native-read-list-download.patch"
host_display_switch_validation_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-host-display-switch-validation.patch"
audio_local_policy_approval_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-audio-local-policy-approval.patch"
viewer_audio_policy_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-audio-explicit-policy.patch"
viewer_audio_permission_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-audio-permission-lifecycle.patch"
host_audio_input_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-host-audio-explicit-input-fail-closed.patch"
native_host_cm_lifetime_patch="$repo_dir/CoreBridge/RustDeskPatch/h7-native-host-cm-lifetime.patch"
hbb_secret_wipe_patch="$repo_dir/CoreBridge/RustDeskPatch/hbb-common-7e1c392.patch"
hbb_bounded_block_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-bounded-block.patch"

[[ -d "$vendor_dir/.git" ]] || {
  print -u2 "RustDesk checkout is missing; run Scripts/bootstrap-rustdesk-core.sh first"
  exit 2
}
[[ -e "$hbb_common_dir/.git" ]] || {
  print -u2 "hbb_common checkout is missing; run Scripts/bootstrap-rustdesk-core.sh first"
  exit 2
}

actual_commit=$(git -C "$vendor_dir" rev-parse HEAD)
[[ "$actual_commit" == "$pinned_commit" ]] || {
  print -u2 "RustDesk checkout does not match the pinned source revision"
  exit 1
}

git -C "$vendor_dir" diff --check
git -C "$vendor_dir" apply --check --reverse "$native_host_cm_lifetime_patch"
if ! git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_patch" 2>/dev/null; then
  git -C "$vendor_dir" apply --check --reverse "$viewer_file_receive_patch"
  git -C "$vendor_dir" apply --check --reverse "$viewer_file_digest_patch"
fi
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$audio_local_policy_approval_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_policy_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_permission_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_audio_input_patch"

git -C "$hbb_common_dir" diff --check
git -C "$hbb_common_dir" apply --check --reverse "$hbb_secret_wipe_patch"
git -C "$hbb_common_dir" apply --check --reverse "$hbb_bounded_block_patch"

canonical_sources=(
  rdn_bridge.rs
  rdn_host_bridge.rs
  rdn_host_file_transfer.rs
)
for source_name in $canonical_sources; do
  cmp -s \
    "$repo_dir/CoreBridge/RustDeskPatch/$source_name" \
    "$vendor_dir/src/$source_name" || {
      print -u2 "RustDesk generated bridge source differs from its canonical source: $source_name"
      exit 1
    }
done

print "RUSTDESK_CORE_SOURCE_VERIFIED commit=$actual_commit"
