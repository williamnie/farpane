#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
build_dir="$repo_dir/Build"
app_dir="$build_dir/FarPane.app"
build_number=${RDN_BUILD_NUMBER:-$(date +%Y%m%d%H%M)}
signing_identity=${RDN_CODESIGN_IDENTITY:-}
signing_mode=stable-identity

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
swift build -c release --arch arm64
swift build -c release --arch x86_64

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
lipo -create \
  "$repo_dir/.build/arm64-apple-macosx/release/RustDeskNative" \
  "$repo_dir/.build/x86_64-apple-macosx/release/RustDeskNative" \
  -output "$app_dir/Contents/MacOS/RustDeskNative"
cp "$repo_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
cp "$repo_dir/App/FarPane.icns" "$app_dir/Contents/Resources/FarPane.icns"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
cp "$repo_dir/LICENSES/SlopDesk-MIT.txt" "$app_dir/Contents/Resources/"
cp "$repo_dir/LICENSES/RustDesk-AGPL-3.0.txt" "$app_dir/Contents/Resources/"
arm_core="$build_dir/CoreBridge/arm64/liblibrustdesk.dylib"
intel_core="$build_dir/CoreBridge/x86_64/liblibrustdesk.dylib"
if [[ ! -f "$arm_core" || ! -f "$intel_core" ]]; then
  print -u2 "both arm64 and x86_64 RustDesk Core libraries are required for the product app"
  exit 1
fi
for core in "$arm_core" "$intel_core"; do
  nm -gU "$core" | grep -q _rdn_client_send_pointer
  nm -gU "$core" | grep -q _rdn_client_send_key
  nm -gU "$core" | grep -q _rdn_client_send_text
done
lipo -create "$arm_core" "$intel_core" -output "$app_dir/Contents/Frameworks/liblibrustdesk.dylib"
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
print "$app_dir"
