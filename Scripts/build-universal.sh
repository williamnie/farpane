#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
build_dir="$repo_dir/Build"
app_dir="$build_dir/FarPane.app"
launch_agent_source="$repo_dir/App/LaunchAgents/io.rustdesknative.viewer.host-agent.plist"
launch_agent_dir="$app_dir/Contents/Library/LaunchAgents"
launch_agent_target="$app_dir/Contents/Library/LaunchAgents/io.rustdesknative.viewer.host-agent.plist"
build_number=${RDN_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
signing_identity=${RDN_CODESIGN_IDENTITY:-}
signing_mode=stable-identity
architecture_spec=${RDN_BUILD_ARCHITECTURES:-"arm64 x86_64"}
case "$architecture_spec" in
  arm64|x86_64|"arm64 x86_64") ;;
  *)
    print -u2 "RDN_BUILD_ARCHITECTURES must be arm64, x86_64, or 'arm64 x86_64'"
    exit 2
    ;;
esac
build_architectures=(${=architecture_spec})

if [[ -z "$signing_identity" ]]; then
  identities=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null | awk -F\" '/Apple Development:/ {print $2}')}" )
  identities=("${(@)identities:#}")
  if (( ${#identities} == 1 )); then
    signing_identity=$identities[1]
  elif [[ "${RDN_ALLOW_ADHOC_SIGNING:-0}" == 1 ]]; then
    signing_identity=-
    signing_mode=adhoc
  else
    print -u2 "A single Apple Development signing identity is required for stable macOS permissions."
    print -u2 "Set RDN_CODESIGN_IDENTITY explicitly, or use RDN_ALLOW_ADHOC_SIGNING=1 only for non-TCC development."
    exit 2
  fi
fi
[[ "$build_number" == <-> ]] || { print -u2 "RDN_BUILD_NUMBER must contain digits only"; exit 2; }

cd "$repo_dir"
for build_architecture in "${build_architectures[@]}"; do
  swift build -c release --arch "$build_architecture"
done

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" \
  "$app_dir/Contents/Frameworks" "$launch_agent_dir"
rm -f "$app_dir/Contents/Resources/SlopDesk-MIT.txt"
rm -f "$app_dir/Contents/Resources/RustDesk-AGPL-3.0.txt"
app_executables=()
for build_architecture in "${build_architectures[@]}"; do
  app_executable="$repo_dir/.build/$build_architecture-apple-macosx/release/RustDeskNative"
  if [[ "$(lipo -archs "$app_executable")" != "$build_architecture" ]]; then
    print -u2 "Swift executable architecture does not match: $build_architecture"
    exit 1
  fi
  app_executables+=("$app_executable")
done
if (( ${#app_executables} == 1 )); then
  cp "${app_executables[1]}" "$app_dir/Contents/MacOS/RustDeskNative"
else
  lipo -create "${app_executables[@]}" \
    -output "$app_dir/Contents/MacOS/RustDeskNative"
fi
cp "$repo_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -lint "$launch_agent_source" >/dev/null
cp "$launch_agent_source" "$launch_agent_target"
chmod 0644 "$launch_agent_target"
/usr/bin/plutil -lint "$launch_agent_target" >/dev/null
/usr/bin/cmp -s "$launch_agent_source" "$launch_agent_target"
cp "$repo_dir/App/FarPane.icns" "$app_dir/Contents/Resources/FarPane.icns"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
cp "$repo_dir/LICENSE" "$app_dir/Contents/Resources/FarPane-AGPL-3.0.txt"
vcpkg_license_root=
for triplet in arm64-osx x64-osx; do
  candidate="$build_dir/vcpkg/installed/$triplet/share"
  if [[ -f "$candidate/libyuv/copyright" && -f "$candidate/aom/copyright" && \
        -f "$candidate/libvpx/copyright" && -f "$candidate/opus/copyright" ]]; then
    vcpkg_license_root=$candidate
    break
  fi
done
if [[ -z "$vcpkg_license_root" ]]; then
  print -u2 "vcpkg dependency copyright files are required for the distributable app"
  exit 1
fi
dependency_license_dir="$app_dir/Contents/Resources/ThirdPartyLicenses"
mkdir -p "$dependency_license_dir"
rm -f "$dependency_license_dir/AOM.txt" \
  "$dependency_license_dir/libvpx.txt" \
  "$dependency_license_dir/libyuv.txt" \
  "$dependency_license_dir/Opus.txt"
cp "$vcpkg_license_root/aom/copyright" "$dependency_license_dir/AOM.txt"
cp "$vcpkg_license_root/libvpx/copyright" "$dependency_license_dir/libvpx.txt"
cp "$vcpkg_license_root/libyuv/copyright" "$dependency_license_dir/libyuv.txt"
cp "$vcpkg_license_root/opus/copyright" "$dependency_license_dir/Opus.txt"
core_libraries=()
for build_architecture in "${build_architectures[@]}"; do
  core="$build_dir/CoreBridge/$build_architecture/liblibrustdesk.dylib"
  if [[ ! -f "$core" ]]; then
    print -u2 "RustDesk Core is missing for architecture: $build_architecture"
    exit 1
  fi
  if [[ "$(lipo -archs "$core")" != "$build_architecture" ]]; then
    print -u2 "RustDesk Core architecture does not match: $build_architecture"
    exit 1
  fi
  core_libraries+=("$core")
done
for core in "${core_libraries[@]}"; do
  nm -gU "$core" | grep -q _rdn_client_send_pointer
  nm -gU "$core" | grep -q _rdn_client_send_key
  nm -gU "$core" | grep -q _rdn_client_send_text
  nm -gU "$core" | grep -q _rdn_client_send_clipboard_text
  nm -gU "$core" | grep -q _rdn_client_send_clipboard_rich_text
  nm -gU "$core" | grep -q _rdn_client_send_clipboard_image
  nm -gU "$core" | grep -q _rdn_client_file_transfer_cancel
  nm -gU "$core" | grep -q _rdn_client_file_transfer_list_root
  nm -gU "$core" | grep -q _rdn_client_file_transfer_manifest_root
  nm -gU "$core" | grep -q _rdn_client_file_transfer_download_start
done
if (( ${#core_libraries} == 1 )); then
  cp "${core_libraries[1]}" \
    "$app_dir/Contents/Frameworks/liblibrustdesk.dylib"
else
  lipo -create "${core_libraries[@]}" \
    -output "$app_dir/Contents/Frameworks/liblibrustdesk.dylib"
fi
codesign --force --sign "$signing_identity" --timestamp=none \
  "$app_dir/Contents/Frameworks/liblibrustdesk.dylib"
codesign --force --sign "$signing_identity" --timestamp=none "$app_dir"
codesign --verify --deep --strict "$app_dir"

requirement=$(codesign -d -r- "$app_dir" 2>&1)
if [[ "$signing_mode" == stable-identity && "$requirement" == *"cdhash"* ]]; then
  print -u2 "stable signing failed: designated requirement is still bound to a CDHash"
  exit 1
fi

lipo -archs "$app_dir/Contents/MacOS/RustDeskNative"
print "BUILD_NUMBER=$build_number"
print "SIGNING_MODE=$signing_mode"
print "BUILD_ARCHITECTURES=$architecture_spec"
print "$app_dir"
