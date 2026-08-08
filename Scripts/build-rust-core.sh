#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
arch=$(uname -m)
case "$arch" in
  arm64|x86_64) ;;
  *) print -u2 "unsupported architecture: $arch"; exit 2 ;;
esac

"$repo_dir/Scripts/bootstrap-rustdesk-core.sh"
"$repo_dir/Scripts/bootstrap-vcpkg.sh"

vendor_dir="$repo_dir/Vendor/rustdesk"
output_dir="$repo_dir/Build/CoreBridge/$arch"
source_core="$vendor_dir/target/release/liblibrustdesk.dylib"
published_core="$output_dir/liblibrustdesk.dylib"
staged_core=""

cleanup_staged_core() {
  if [[ -n "$staged_core" && -e "$staged_core" ]]; then
    /bin/rm -f -- "$staged_core"
  fi
}
trap cleanup_staged_core EXIT

mkdir -p "$output_dir"
(
  cd "$vendor_dir"
  VCPKG_ROOT="$repo_dir/Build/vcpkg" \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" \
    cargo build --release --features rdn-native-core,rdn-native-host --lib
)
staged_core=$(mktemp "$output_dir/.liblibrustdesk.dylib.XXXXXX")
cp -p "$source_core" "$staged_core"

file "$staged_core"
nm -gU "$staged_core" | grep -q _rdn_core_abi_version
nm -gU "$staged_core" | grep -q _rdn_client_connect
nm -gU "$staged_core" | grep -q _rdn_client_request_keyframe
nm -gU "$staged_core" | grep -q _rdn_client_send_pointer
nm -gU "$staged_core" | grep -q _rdn_client_send_key
nm -gU "$staged_core" | grep -q _rdn_client_send_text
nm -gU "$staged_core" | grep -q _rdn_host_abi_version
nm -gU "$staged_core" | grep -q _rdn_host_set_config_root
nm -gU "$staged_core" | grep -q _rdn_host_create
nm -gU "$staged_core" | grep -q _rdn_host_start
nm -gU "$staged_core" | grep -q _rdn_host_stop
nm -gU "$staged_core" | grep -q _rdn_host_command
nm -gU "$staged_core" | grep -q _rdn_host_set_permanent_password
nm -gU "$staged_core" | grep -q _rdn_host_copy_snapshot
nm -gU "$staged_core" | grep -q _rdn_host_destroy
nm -gU "$staged_core" | grep -q _rdn_host_media_abi_version
nm -gU "$staged_core" | grep -q _rdn_host_media_set_capabilities
nm -gU "$staged_core" | grep -q _rdn_host_media_submit_access_unit
nm -gU "$staged_core" | grep -q _rdn_host_media_report_encoder_state

# A same-directory rename publishes a complete new inode and avoids stale
# linker-signature cache state from overwriting an already loaded dylib.
mv -f "$staged_core" "$published_core"
staged_core=""
print "RUSTDESK_CORE_BUILT path=$published_core"
