#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
source_app=${1:-$repo_dir/Build/FarPane.app}
install_parent=${RDN_INSTALL_DIRECTORY:-$HOME/Applications}
installed_app="$install_parent/FarPane.app"
legacy_installed_app="$install_parent/RustDesk Native Viewer.app"
backup_parent="$HOME/Library/Application Support/RustDesk Native Viewer/Install Backups"

[[ -d "$source_app" ]] || { print -u2 "product app not found: $source_app"; exit 2; }
codesign --verify --deep --strict "$source_app"
source_requirement=$(codesign -d -r- "$source_app" 2>&1 | tail -1)
[[ "$source_requirement" != *"cdhash"* ]] || {
  print -u2 "refusing to install a CDHash-bound app that would lose TCC permissions after rebuild"
  exit 2
}

mkdir -p "$install_parent"
stage=$(mktemp -d "$install_parent/.farpane-install.XXXXXX")
trap 'rm -rf "$stage"' EXIT INT TERM
staged_app="$stage/FarPane.app"
/usr/bin/ditto "$source_app" "$staged_app"
codesign --verify --deep --strict "$staged_app"

if [[ -e "$installed_app" ]]; then
  mkdir -p "$backup_parent"
  backup="$backup_parent/FarPane-$(date +%Y%m%d-%H%M%S).app"
  mv "$installed_app" "$backup"
  print "PREVIOUS_APP_BACKUP=$backup"
fi
if [[ -e "$legacy_installed_app" ]]; then
  mkdir -p "$backup_parent"
  legacy_backup="$backup_parent/RustDesk Native Viewer-$(date +%Y%m%d-%H%M%S).app"
  mv "$legacy_installed_app" "$legacy_backup"
  print "LEGACY_APP_BACKUP=$legacy_backup"
fi
mv "$staged_app" "$installed_app"
trap - EXIT INT TERM
rmdir "$stage"

installed_requirement=$(codesign -d -r- "$installed_app" 2>&1 | tail -1)
[[ "$installed_requirement" == "$source_requirement" ]] || {
  print -u2 "installed app signing requirement changed unexpectedly"
  exit 1
}
/usr/bin/plutil -extract CFBundleIdentifier raw "$installed_app/Contents/Info.plist"
print "INSTALLED_APP=$installed_app"
