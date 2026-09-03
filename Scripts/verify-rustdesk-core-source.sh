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
native_host_file_permission_readiness_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-native-host-file-permission-readiness.patch"
audio_local_policy_approval_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-audio-local-policy-approval.patch"
viewer_audio_policy_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-audio-explicit-policy.patch"
viewer_audio_permission_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-viewer-audio-permission-lifecycle.patch"
host_audio_input_patch="$repo_dir/CoreBridge/RustDeskPatch/h6-host-audio-explicit-input-fail-closed.patch"
host_audio_sck_stop_patch="$repo_dir/CoreBridge/RustDeskPatch/h7-host-audio-sck-stop.patch"
native_host_cm_lifetime_patch="$repo_dir/CoreBridge/RustDeskPatch/h7-native-host-cm-lifetime.patch"
native_host_physical_display_pixels_patch="$repo_dir/CoreBridge/RustDeskPatch/h7-native-host-physical-display-pixels.patch"
android_annex_b_interoperability_patch="$repo_dir/CoreBridge/RustDeskPatch/h8-android-annex-b-interoperability.patch"
android_first_frame_compatibility_patch="$repo_dir/CoreBridge/RustDeskPatch/h9-android-first-frame-compatibility.patch"
android_software_codec_fallback_patch="$repo_dir/CoreBridge/RustDeskPatch/h10-android-software-codec-fallback.patch"
macos_scroll_modifiers_patch="$repo_dir/CoreBridge/RustDeskPatch/h11-macos-scroll-modifiers.patch"
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
git -C "$vendor_dir" apply --check --reverse "$android_software_codec_fallback_patch"
git -C "$vendor_dir" apply --check --reverse "$macos_scroll_modifiers_patch"

# H10 overlaps H9 and H8 context, so verify the layered chain against temporary
# copies rather than modifying the generated checkout during verification.
patch_check_dir=$(mktemp -d "$vendor_dir/.android-patch-check.XXXXXX")
trap 'rm -r -- "$patch_check_dir"' EXIT
mkdir -p "$patch_check_dir/src/server"
cp "$vendor_dir/src/server/connection.rs" "$patch_check_dir/src/server/connection.rs"
cp "$vendor_dir/src/server/service.rs" "$patch_check_dir/src/server/service.rs"
cp "$vendor_dir/src/server/video_service.rs" "$patch_check_dir/src/server/video_service.rs"
patch_check_relative=${patch_check_dir#"$vendor_dir"/}
git -C "$vendor_dir" apply \
  --directory="$patch_check_relative" \
  --reverse \
  "$android_software_codec_fallback_patch"
git -C "$vendor_dir" apply \
  --directory="$patch_check_relative" \
  --reverse \
  "$android_first_frame_compatibility_patch"
git -C "$vendor_dir" apply \
  --directory="$patch_check_relative" \
  --check \
  --reverse \
  "$android_annex_b_interoperability_patch"
rm -r -- "$patch_check_dir"
trap - EXIT
git -C "$vendor_dir" apply --check --reverse "$native_host_physical_display_pixels_patch"
git -C "$vendor_dir" apply --check --reverse "$native_host_cm_lifetime_patch"
if ! git -C "$vendor_dir" apply --check --reverse "$viewer_file_upload_patch" 2>/dev/null; then
  git -C "$vendor_dir" apply --check --reverse "$viewer_file_receive_patch"
  git -C "$vendor_dir" apply --check --reverse "$viewer_file_digest_patch"
fi
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_display_switch_validation_patch"
git -C "$vendor_dir" apply --check --reverse "$native_host_file_permission_readiness_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$audio_local_policy_approval_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_policy_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$viewer_audio_permission_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_audio_input_patch"
git -C "$vendor_dir" apply --unidiff-zero --check --reverse "$host_audio_sck_stop_patch"

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
"$repo_dir/Scripts/prepare-cpal-screencapturekit.sh" --verify-only >/dev/null
