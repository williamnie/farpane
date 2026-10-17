#!/usr/bin/env bash
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
reference=${1:?Usage: build-native-app.sh READ_ONLY_REFERENCE_CACHE}
cd "$repo"
receipt_dir=$(mktemp -d "$repo/Build/Linux/native-build-receipt.XXXXXX")
python3 -B Linux/packaging/native_receipt.py snapshot > "$receipt_dir/sources.json"
# Prepare canonical changes explicitly first. Never overwrite unknown generated
# edits or rebuild FFmpeg from this application-only entrypoint.
python3 -B Scripts/linux/verify-sources.py --reference "$reference"
python3 -B Scripts/linux/prepare-native.py --check
Scripts/linux/container.sh /workspace/Scripts/linux/build-native-core.sh release
Scripts/linux/native-container.sh -c 'cd /workspace/Build/Linux/gui && cargo build --offline --locked --release'
Scripts/linux/container.sh -c '/workspace/Build/Linux/target/release/farpane-core --build-info' > "$receipt_dir/core.json"
Scripts/linux/native-container.sh -c '/workspace/Build/Linux/native-target/release/farpane --build-info' > "$receipt_dir/gui.json"
python3 -B Scripts/linux/verify-sources.py --reference "$reference"
python3 -B Scripts/linux/prepare-native.py --check
python3 -B Linux/packaging/native_receipt.py finish "$receipt_dir/sources.json" "$receipt_dir/core.json" "$receipt_dir/gui.json"
