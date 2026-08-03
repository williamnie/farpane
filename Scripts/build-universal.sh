#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
build_dir="$repo_dir/Build"
app_dir="$build_dir/RustDeskNative.app"

cd "$repo_dir"
swift build -c release --arch arm64
swift build -c release --arch x86_64

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
lipo -create \
  "$repo_dir/.build/arm64-apple-macosx/release/RustDeskNative" \
  "$repo_dir/.build/x86_64-apple-macosx/release/RustDeskNative" \
  -output "$app_dir/Contents/MacOS/RustDeskNative"
cp "$repo_dir/App/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
cp "$repo_dir/LICENSES/SlopDesk-MIT.txt" "$app_dir/Contents/Resources/"
cp "$repo_dir/LICENSES/RustDesk-AGPL-3.0.txt" "$app_dir/Contents/Resources/"
arm_core="$build_dir/CoreBridge/arm64/liblibrustdesk.dylib"
intel_core="$build_dir/CoreBridge/x86_64/liblibrustdesk.dylib"
if [[ -f "$arm_core" && -f "$intel_core" ]]; then
  for core in "$arm_core" "$intel_core"; do
    nm -gU "$core" | grep -q _rdn_client_send_pointer
    nm -gU "$core" | grep -q _rdn_client_send_key
    nm -gU "$core" | grep -q _rdn_client_send_text
  done
  lipo -create "$arm_core" "$intel_core" -output "$app_dir/Contents/Frameworks/liblibrustdesk.dylib"
  codesign --force --sign - "$app_dir/Contents/Frameworks/liblibrustdesk.dylib"
elif [[ -e "$app_dir/Contents/Frameworks/liblibrustdesk.dylib" ]]; then
  print -u2 "refusing to retain a stale bundled Core when one architecture is missing"
  exit 1
fi
codesign --force --sign - "$app_dir"

lipo -archs "$app_dir/Contents/MacOS/RustDeskNative"
print "$app_dir"
