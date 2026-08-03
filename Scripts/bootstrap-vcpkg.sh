#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
vcpkg_dir="$repo_dir/Build/vcpkg"
pinned_commit=120deac3062162151622ca4860575a33844ba10b

case "$(uname -m)" in
  arm64) triplet=arm64-osx ;;
  x86_64)
    triplet=x64-osx
    nasm_root="$repo_dir/Build/tools/nasm-2.16.03"
    nasm_zip="$repo_dir/Build/tools/nasm-2.16.03-macosx.zip"
    if [[ ! -x "$nasm_root/nasm" ]]; then
      mkdir -p "${nasm_zip:h}"
      curl -fL https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip -o "$nasm_zip"
      expected_nasm_sha=0d29bcd8a5fc617333f4549c7c1f93d1866a4a0915c40359e0a8585bb1a5aa75
      actual_nasm_sha=$(shasum -a 256 "$nasm_zip" | awk '{print $1}')
      if [[ "$actual_nasm_sha" != "$expected_nasm_sha" ]]; then
        print -u2 "NASM archive checksum mismatch"
        exit 1
      fi
      ditto -x -k "$nasm_zip" "$repo_dir/Build/tools"
    fi
    export PATH="$nasm_root:$PATH"
    ;;
  *) print -u2 "unsupported architecture: $(uname -m)"; exit 2 ;;
esac

if [[ ! -d "$vcpkg_dir/.git" ]]; then
  mkdir -p "${vcpkg_dir:h}"
  git clone https://github.com/microsoft/vcpkg.git "$vcpkg_dir"
  git -C "$vcpkg_dir" checkout "$pinned_commit"
fi
actual_commit=$(git -C "$vcpkg_dir" rev-parse HEAD)
if [[ "$actual_commit" != "$pinned_commit" ]]; then
  print -u2 "vcpkg checkout mismatch: expected=$pinned_commit actual=$actual_commit"
  exit 1
fi

if [[ ! -x "$vcpkg_dir/vcpkg" ]]; then
  "$vcpkg_dir/bootstrap-vcpkg.sh" -disableMetrics
fi
"$vcpkg_dir/vcpkg" install \
  "libyuv:$triplet" \
  "aom:$triplet" \
  "libvpx:$triplet" \
  "opus:$triplet"
print "VCPKG_READY commit=$actual_commit triplet=$triplet"
