#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
vendor_dir="$repo_dir/Vendor/rustdesk"
patch_file="$repo_dir/CoreBridge/RustDeskPatch/cpal-screencapturekit-fast-display-enumeration.patch"
expected_revision=6b374bcaed076750ca8fce6da518ab39b882e14a
expected_source_prefix='git+https://github.com/rustdesk-org/cpal?branch=osx-screencapturekit#'
patch_digest=$(shasum -a 256 "$patch_file" | awk '{print $1}')
cache_stamp="$vendor_dir/target/.farpane-cpal-screencapturekit-$expected_revision-$patch_digest"
mode=${1:-prepare}
[[ "$mode" == prepare || "$mode" == --verify-only ]] || {
  print -u2 "usage: ${0:t} [--verify-only]"
  exit 2
}

command -v python3 >/dev/null || {
  print -u2 "python3 is required to resolve the pinned cpal checkout"
  exit 2
}

metadata=$(cargo metadata --locked --format-version 1 --manifest-path "$vendor_dir/Cargo.toml")
resolved=$(print -r -- "$metadata" | python3 -c '
import json
import sys

prefix = "git+https://github.com/rustdesk-org/cpal?branch=osx-screencapturekit#"
matches = [
    package
    for package in json.load(sys.stdin)["packages"]
    if package["name"] == "cpal" and (package.get("source") or "").startswith(prefix)
]
if len(matches) == 1:
    print(matches[0]["manifest_path"] + "\t" + matches[0]["source"])
')
[[ -n "$resolved" ]] || {
  print -u2 "Unable to resolve exactly one pinned RustDesk cpal checkout"
  exit 1
}

cpal_manifest=${resolved%%$'\t'*}
cpal_source=${resolved#*$'\t'}
cpal_dir=${cpal_manifest:h}
[[ "$cpal_source" == "$expected_source_prefix$expected_revision" ]] || {
  print -u2 "cpal checkout mismatch: expected=$expected_revision source=$cpal_source"
  exit 1
}
[[ "$(git -C "$cpal_dir" rev-parse HEAD)" == "$expected_revision" ]] || {
  print -u2 "cpal worktree revision does not match Cargo.lock"
  exit 1
}

if git -C "$cpal_dir" apply --unidiff-zero --check "$patch_file" 2>/dev/null; then
  if [[ "$mode" == --verify-only ]]; then
    print -u2 "cpal checkout is pinned but the ScreenCaptureKit patch is not prepared"
    exit 1
  fi
  git -C "$cpal_dir" apply --unidiff-zero "$patch_file"
elif ! git -C "$cpal_dir" apply --unidiff-zero --check --reverse "$patch_file" 2>/dev/null; then
  print -u2 "cpal checkout has changes that do not match the fast ScreenCaptureKit enumeration patch"
  git -C "$cpal_dir" status --short >&2
  exit 1
fi

git -C "$cpal_dir" diff --check
git -C "$cpal_dir" apply --unidiff-zero --check --reverse "$patch_file"
if [[ "$mode" == --verify-only ]]; then
  print "CPAL_SCREENCAPTUREKIT_SOURCE_VERIFIED revision=$expected_revision"
else
  # Cargo treats git dependencies as immutable and can reuse an artifact that
  # predates this local patch. Invalidate only cpal once per patch digest so a
  # prepared checkout and its compiled artifact cannot silently disagree.
  if [[ ! -f "$cache_stamp" ]]; then
    cargo clean --manifest-path "$vendor_dir/Cargo.toml" -p cpal
    mkdir -p "$vendor_dir/target"
    touch "$cache_stamp"
  fi
  print "CPAL_SCREENCAPTUREKIT_SOURCE_READY revision=$expected_revision"
fi
