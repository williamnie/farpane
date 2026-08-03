# Phase 2 strict live preflight

This is the final 60-second preflight immediately preceding the accepted run.
It used the same Intel release executable, x86_64 Rust Core dylib, secure Hermes
relay path, 4096x2304 HiDPI source, and GPU-driven 30 Hz motion source as the
formal run.

The strict wrapper exited 0. Highlights from `report.json`:

- 60.063 seconds, 4096x2304 H265, Annex-B only.
- 1,868 encoded and hardware-decoded frames; 1,714 presented frames.
- 31.246 encoded FPS and 28.744 presented FPS over the active stream.
- 0 decode errors, reference-frame drops, decoder resets, and keyframe requests.
- Decoder queue max 2 and renderer NV12 IOSurface queue max 2.
- 2.390% process CPU and 0.387 MB steady-state memory growth.

The files contain no connection identifiers or credentials. Verify them with
`shasum -a 256 -c SHA256SUMS` from this directory.
