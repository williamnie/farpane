#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
arch=$(uname -m)
case "$arch" in
  arm64|x86_64) ;;
  *) print -u2 "unsupported architecture: $arch"; exit 2 ;;
esac

core="$repo_dir/Build/CoreBridge/$arch/liblibrustdesk.dylib"
app=${RDN_HOST_GOLDEN_APP:-$HOME/Applications/FarPane.app}
app_executable="$app/Contents/MacOS/RustDeskNative"
app_core="$app/Contents/Frameworks/liblibrustdesk.dylib"
[[ -f "$core" ]] || {
  print -u2 "Host Core is missing: $core"
  print -u2 "Build it first with Scripts/build-rust-core.sh"
  exit 2
}

core_archs=$(lipo -archs "$core")
[[ " $core_archs " == *" $arch "* ]] || {
  print -u2 "Host Core does not contain the current architecture: $core_archs"
  exit 1
}

required_symbols=(
  _rdn_host_abi_version
  _rdn_host_start
  _rdn_host_recover_network_path
  _rdn_host_begin_sleep
  _rdn_host_finish_sleep
  _rdn_host_resume_after_wake
  _rdn_host_copy_snapshot
  _rdn_host_set_permanent_password
  _rdn_host_media_abi_version
  _rdn_host_media_set_capabilities
  _rdn_host_media_submit_access_unit
  _rdn_host_media_report_encoder_state
)
exported_symbols=$(nm -gU "$core")
for symbol in $required_symbols; do
  [[ "$exported_symbols" == *"$symbol"* ]] || {
    print -u2 "Host Core is missing required symbol: $symbol"
    exit 1
  }
done

"$repo_dir/Scripts/verify-rustdesk-core-source.sh"

cd "$repo_dir"
swift build -c release
release_executable="$(swift build -c release --show-bin-path)/RustDeskNative"

[[ -x "$app_executable" ]] || {
  print -u2 "Golden Connection App is missing: $app"
  print -u2 "Build and install the latest signed App before running this preflight"
  exit 2
}
[[ -f "$app_core" ]] || {
  print -u2 "Golden Connection App has no bundled Core: $app_core"
  exit 2
}
codesign --verify --deep --strict "$app"
app_requirement=$(codesign -d -r- "$app" 2>&1 | tail -1)
[[ "$app_requirement" != *"cdhash"* ]] || {
  print -u2 "Golden Connection App uses a CDHash-bound identity and cannot retain TCC permissions"
  exit 2
}

uuid_for_arch() {
  dwarfdump --uuid "$1" | awk -v target="($arch)" '$3 == target {print $2; exit}'
}
release_uuid=$(uuid_for_arch "$release_executable")
app_executable_uuid=$(uuid_for_arch "$app_executable")
core_uuid=$(uuid_for_arch "$core")
app_core_uuid=$(uuid_for_arch "$app_core")
[[ -n "$release_uuid" && -n "$app_executable_uuid" && "$release_uuid" == "$app_executable_uuid" ]] || {
  print -u2 "Golden Connection App executable does not match the latest release build"
  print -u2 "Rebuild and install it before the FarPane controller run: $app"
  exit 1
}
[[ -n "$core_uuid" && -n "$app_core_uuid" && "$core_uuid" == "$app_core_uuid" ]] || {
  print -u2 "Golden Connection App bundled Core does not match the verified Host Core"
  print -u2 "Rebuild and install it before the FarPane controller run: $app"
  exit 1
}

diagnostic_log=$(mktemp -t farpane-h1-diagnostic.XXXXXX)
media_log=$(mktemp -t farpane-h1-media.XXXXXX)
cleanup() {
  rm -f "$diagnostic_log" "$media_log"
}
trap cleanup EXIT

RDN_CORE_LIBRARY="$core" swift test \
  --filter CoreBridgeContractTests/testHostMediaDiagnosticIsSanitizedAndFailsClosed \
  | tee "$diagnostic_log"
if rg -qi "skipped|XCTSkip" "$diagnostic_log" || \
   ! rg -q "Executed 1 test, with 0 failures" "$diagnostic_log"; then
  print -u2 "Sanitized media-diagnostic contract did not execute successfully"
  exit 1
fi

RDN_CORE_LIBRARY="$core" swift test \
  --filter HostMediaPipelineTests/testAuthorizedScreenCaptureReachesHardwareEncoder \
  | tee "$media_log"
if rg -qi "skipped|XCTSkip" "$media_log" || \
   ! rg -q "Executed 1 test, with 0 failures" "$media_log"; then
  print -u2 "Real ScreenCaptureKit to hardware H.264 preflight did not execute successfully"
  exit 1
fi

core_sha256=$(shasum -a 256 "$core" | awk '{print $1}')
print "H1_GOLDEN_PREFLIGHT_READY"
print "CORE_ARCH=$arch"
print "CORE_SHA256=$core_sha256"
print "APP=$app"
print "NEXT=Use another machine with FarPane Viewer; follow docs/host-mode-h1-golden-connection.md"
