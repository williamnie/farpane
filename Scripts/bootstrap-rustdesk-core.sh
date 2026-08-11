#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
vendor_dir="$repo_dir/Vendor/rustdesk"
pinned_commit=6c578292e8ebbbec708b76986ba8c4bc7c509747
patch_file="$repo_dir/CoreBridge/RustDeskPatch/upstream-1.4.9.patch"
rich_text_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-rich-text-transfer.patch"
viewer_image_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-image-api.patch"
viewer_file_receive_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-file-receive-interception.patch"
viewer_file_digest_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-file-digest-confirmation.patch"
viewer_file_upload_wire_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-file-upload-wire.patch"
hbb_common_patch_file="$repo_dir/CoreBridge/RustDeskPatch/hbb-common-7e1c392.patch"
file_transfer_block_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-bounded-block.patch"
file_transfer_mutation_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-mutation-dispatch.patch"
file_transfer_native_new_write_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-native-new-write.patch"
file_transfer_native_resume_digest_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-native-resume-digest.patch"
file_transfer_native_existing_target_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-native-existing-target.patch"
file_transfer_native_read_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-file-transfer-native-read-list-download.patch"
host_display_switch_validation_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-host-display-switch-validation.patch"
audio_local_policy_approval_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-audio-local-policy-approval.patch"
viewer_audio_policy_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-audio-explicit-policy.patch"
viewer_audio_permission_patch_file="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-audio-permission-lifecycle.patch"
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
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The final Host display-selection validation layer proves the expected
  # connection.rs stack is already present.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_read_patch_file" 2>/dev/null; then
  # The native-read layer is the final connection.rs extension and proves all
  # lower connection layers are present in the expected order.
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
elif git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_wire_patch_file" 2>/dev/null; then
  # The upload-wire layer is applied after all Viewer file hooks and proves
  # the lower image API layer is present.
  :
elif git -C "$vendor_dir" apply --check --reverse "$viewer_file_receive_patch_file" 2>/dev/null; then
  # The Viewer receive hook is layered immediately after the image hook and
  # its reverse applicability proves the image trait extension is present.
  :
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_image_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer image API patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$rich_text_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$rich_text_patch_file"
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The final display-selection layer overlaps handle_switch_display and proves
  # the lower rich-text connection extension is already present.
  :
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$rich_text_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 rich-text transfer patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$viewer_file_receive_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$viewer_file_receive_patch_file"
elif git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_wire_patch_file" 2>/dev/null; then
  # The final Viewer upload-wire layer proves receive interception is present.
  :
elif ! git -C "$vendor_dir" apply --check --reverse "$viewer_file_receive_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer file receive patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$viewer_file_digest_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$viewer_file_digest_patch_file"
elif git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_wire_patch_file" 2>/dev/null; then
  # The upload-wire layer extends digest handling and proves the lower digest
  # confirmation hook is present.
  :
elif ! git -C "$vendor_dir" apply --check --reverse "$viewer_file_digest_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer file digest patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$viewer_file_upload_wire_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$viewer_file_upload_wire_patch_file"
elif ! git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_wire_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer upload wire patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$file_transfer_mutation_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$file_transfer_mutation_patch_file"
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The final Host display-selection layer proves the lower connection layers.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_read_patch_file" 2>/dev/null; then
  # The final native-read layer proves the lower mutation layer is present.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_existing_target_patch_file" 2>/dev/null; then
  # The existing-target layer overlaps the later write layers. Its reverse
  # applicability proves the lower mutation layer is already present.
  :
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$file_transfer_native_resume_digest_patch_file" 2>/dev/null; then
  # The resume-digest layer overlaps both later file-write layers. Its reverse
  # applicability proves the lower mutation layer is already present.
  :
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$file_transfer_native_new_write_patch_file" 2>/dev/null; then
  # The new-write layer overlaps connection.rs mutation-dispatch context; its
  # reverse applicability proves both layers are present in the expected order.
  :
elif ! git -C "$vendor_dir" apply --check --reverse "$file_transfer_mutation_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 file-transfer mutation patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$file_transfer_native_new_write_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$file_transfer_native_new_write_patch_file"
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The final Host display-selection layer proves the lower connection layers.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_read_patch_file" 2>/dev/null; then
  # The final native-read layer proves the lower new-write layer is present.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_existing_target_patch_file" 2>/dev/null; then
  # The existing-target layer proves the lower new-write layer is present.
  :
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$file_transfer_native_resume_digest_patch_file" 2>/dev/null; then
  # The resume-digest layer rewrites new-write connection hooks. Its reverse
  # applicability proves the new-write layer is already present underneath.
  :
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$file_transfer_native_new_write_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 native new-write patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$file_transfer_native_resume_digest_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$file_transfer_native_resume_digest_patch_file"
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The final Host display-selection layer proves the lower connection layers.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_read_patch_file" 2>/dev/null; then
  # The final native-read layer proves the lower resume-digest layer is present.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_existing_target_patch_file" 2>/dev/null; then
  # The existing-target layer rewrites resume digest confirmation hooks. Its
  # reverse applicability proves the resume layer is present underneath.
  :
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$file_transfer_native_resume_digest_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 native resume-digest patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$file_transfer_native_existing_target_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$file_transfer_native_existing_target_patch_file"
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The final Host display-selection layer proves the lower connection layers.
  :
elif git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_read_patch_file" 2>/dev/null; then
  # The final native-read layer was applied on top of existing-target.
  :
elif ! git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_existing_target_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 native existing-target patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --check "$file_transfer_native_read_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply "$file_transfer_native_read_patch_file"
elif git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  # The Host display-selection validation layer is applied last and proves the
  # lower native read/list/download layer is present.
  :
elif ! git -C "$vendor_dir" apply --check --reverse "$file_transfer_native_read_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 native read/list/download patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$host_display_switch_validation_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$host_display_switch_validation_patch_file"
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Host display-switch validation patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$audio_local_policy_approval_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$audio_local_policy_approval_patch_file"
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$audio_local_policy_approval_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 audio local-policy approval patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$viewer_audio_policy_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$viewer_audio_policy_patch_file"
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_policy_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer audio policy patch"
  git -C "$vendor_dir" status --short >&2
  exit 1
fi

if git -C "$vendor_dir" apply --unidiff-zero --check "$viewer_audio_permission_patch_file" 2>/dev/null; then
  git -C "$vendor_dir" apply --unidiff-zero "$viewer_audio_permission_patch_file"
elif ! git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_permission_patch_file" 2>/dev/null; then
  print -u2 "RustDesk checkout has changes that do not match the H6 Viewer audio permission patch"
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

# Both native bridges are wholly owned by this repository; tracked sources are
# authoritative and always synced into the generated vendor checkout.
cp "$bridge_source" "$vendor_dir/src/rdn_bridge.rs"
cp "$host_bridge_source" "$vendor_dir/src/rdn_host_bridge.rs"
cp "$host_file_transfer_source" "$vendor_dir/src/rdn_host_file_transfer.rs"

git -C "$vendor_dir" diff --check
if git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_wire_patch_file" 2>/dev/null; then
  :
else
  git -C "$vendor_dir" apply --check --reverse "$viewer_file_receive_patch_file"
  git -C "$vendor_dir" apply --check --reverse "$viewer_file_digest_patch_file"
fi
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch_file"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$audio_local_policy_approval_patch_file"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_policy_patch_file"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_permission_patch_file"
git -C "$hbb_common_dir" diff --check
git -C "$hbb_common_dir" apply --check --reverse "$hbb_common_patch_file"
git -C "$hbb_common_dir" apply --check --reverse "$file_transfer_block_patch_file"
if ! cmp -s "$vendor_dir/src/rdn_host_file_transfer.rs" "$host_file_transfer_source"; then
  print -u2 "native Host file-transfer root source differs from its canonical source"
  exit 1
fi
print "RUSTDESK_CORE_SOURCE_READY commit=$actual_commit"
