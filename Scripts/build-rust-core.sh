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
mkdir -p "$output_dir"
(
  cd "$vendor_dir"
  VCPKG_ROOT="$repo_dir/Build/vcpkg" \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-1}" \
    cargo build --release --features rdn-native-core --lib
)
cp "$vendor_dir/target/release/liblibrustdesk.dylib" "$output_dir/"

file "$output_dir/liblibrustdesk.dylib"
nm -gU "$output_dir/liblibrustdesk.dylib" | grep -q _rdn_core_abi_version
nm -gU "$output_dir/liblibrustdesk.dylib" | grep -q _rdn_client_connect
nm -gU "$output_dir/liblibrustdesk.dylib" | grep -q _rdn_client_request_keyframe
nm -gU "$output_dir/liblibrustdesk.dylib" | grep -q _rdn_client_send_pointer
nm -gU "$output_dir/liblibrustdesk.dylib" | grep -q _rdn_client_send_key
nm -gU "$output_dir/liblibrustdesk.dylib" | grep -q _rdn_client_send_text
print "RUSTDESK_CORE_BUILT path=$output_dir/liblibrustdesk.dylib"
