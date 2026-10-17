#!/usr/bin/env bash
set -euo pipefail
cd /workspace/Build/Linux/src/rustdesk
# This combination must not enable Flutter/Sciter/GTK3 through default features.
case "${1:-check}" in
  check) cargo check --offline --locked --no-default-features --features farpane-native,linux-gpu-media --bin farpane-core ;;
  debug) cargo build --offline --locked --no-default-features --features farpane-native,linux-gpu-media --bin farpane-core ;;
  release) cargo build --offline --locked --release --no-default-features --features farpane-native,linux-gpu-media --bin farpane-core ;;
  *) echo 'Usage: build-native-core.sh [check|debug|release]' >&2; exit 2 ;;
esac
