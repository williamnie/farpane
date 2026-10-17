#!/usr/bin/env bash
set -euo pipefail
cd /workspace/Build/Linux/src/rustdesk
cargo test --offline --locked -p hbb_common --features farpane-native config::farpane -- --test-threads=1
cargo test --offline --locked --no-default-features --features farpane-native,linux-gpu-media --lib farpane_native:: -- --test-threads=1
cargo test --offline --locked -p scrap --features linux-gpu-media,native-viewer linux_gpu::tests -- --test-threads=1
cargo check --offline --locked --lib --features flutter,hwcodec,drm,farpane-linux,linux-gpu-media
