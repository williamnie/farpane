#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo"
mkdir -p Build/Linux/source-audit/input
# Cargo resolves the locked target graph only; neither command compiles or fetches.
Scripts/linux/container.sh -c 'set -e
cd Build/Linux/src/rustdesk
cargo metadata --offline --locked --filter-platform x86_64-unknown-linux-gnu --no-default-features --features farpane-native,linux-gpu-media --format-version 1 > /workspace/Build/Linux/source-audit/input/core.json
cd /workspace/Build/Linux/gui
cargo metadata --offline --locked --filter-platform x86_64-unknown-linux-gnu --format-version 1 > /workspace/Build/Linux/source-audit/input/gui.json'
exec python3 -B Scripts/linux/audit-native-sources.py \
  --core-metadata Build/Linux/source-audit/input/core.json \
  --gui-metadata Build/Linux/source-audit/input/gui.json
