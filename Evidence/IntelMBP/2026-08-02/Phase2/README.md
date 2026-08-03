# Phase 2 Intel MBP evidence (incomplete acceptance)

This directory contains fresh Intel MBP evidence from 2026-08-02. It must not
be interpreted as completed Phase 2 acceptance.

- `environment.txt` records macOS 13.7.8, Xcode 15.2, Swift 5.9.2, Rust 1.82,
  the pinned RustDesk/vcpkg commits, x86_64 ABI symbols, dylib SHA-256, and
  `minos 13.0`.
- `core-build-verify.log` records the final x86_64 Rust core release rebuild
  from the formatted bridge source (exit 0).
- `core-build-housekeeping.log` and `core-housekeeping-test.log` record the
  later x86_64 rebuild plus the focused Rust control-housekeeping test (1/1).
- `swift-tests-final-gates.log` and `swift-build-final-gates.log` record the
  latest real-dylib Intel test pass (12/12) and Release build.
- `core-build-profile-isolation.log`, `swift-tests-profile-isolation.log`, and
  `swift-build-profile-isolation.log` record the subsequent target-profile
  persistence repair rebuild, another 12/12 real-dylib pass, and Release build.
- `swift-tests.log` records the earlier 10-test ABI v1 checkpoint, including loading the real
  x86_64 Rust core, verifying ABI/upstream commit, and validating measured
  encoded-frame diagnostics. It also records a successful release build.
- `smoke.json` and `smoke.log` record a real Hermes transport attempt. It
  reached `transportReady` with 26 ms network delay, then stopped at
  `passwordRequired`; consequently it received zero encoded packets.
- `freeze-reproduction-1800s/` records the later authenticated 1800-second
  Hermes-to-Mac-mini run. It received 46,465 real 2048x1152 Annex-B H265
  packets without sequence gaps, but presented only 1,760 frames and logged
  44,680 decode errors. That directory is deliberately marked failed and is
  retained as the reproducible pre-fix freeze evidence, not acceptance.
- `hidpi-transition-smoke-121s/` records the first post-recovery smoke, during
  which the user enabled HiDPI and the remote encoded mode changed from
  2048x1152 to 4096x2304. The simultaneous display/encoder hot transition was
  followed by an early disconnect, so this is also failed diagnostic evidence,
  not fixed-display Phase 2 acceptance.
- `direct-fixed-hidpi-smoke-131s/` records a fixed 4096x2304 direct-connection
  run. Its video pipeline was clean (2,919/2,919 decoded, zero decode errors,
  reference drops, resets, or backpressure waits), but the direct TCP session
  ended after 131.44 seconds. It is retained as failed transport evidence; the
  next diagnostic uses the Hermes relay path.
- `relay-4k-smoke-29s/` records the forced secure Hermes relay diagnostic. It
  measured 10 ms delay and decoded all 373 received 4096x2304 frames without
  errors, but presentation staleness reached 7.18 seconds and the remote relay
  path closed with `deadline has elapsed` after 28.95 seconds. This is failed
  transport evidence, not acceptance.
- `direct-1152p-reset-60s/` records the return to a fixed 2048x1152 secure
  direct stream. Its 1,099 received frames all hardware-decoded without error,
  but the Core classified `connection-reset` after 60.21 seconds while the Mac
  mini socket reported `Operation timed out`. This is failed transport evidence.
- `housekeeping-smoke-180s/` records the first successful post-housekeeping
  recovery smoke: 180.08 seconds secure-direct, 4,780/4,780 hardware-decoded
  frames, 4,752 presentations, queue depth two, and zero decode errors,
  reference drops, resets, packet gaps, or final presentation lag. It remains
  diagnostic rather than acceptance because the Mac mini was still using the
  2048x1152 low-resolution mode.
- `4k-housekeeping-smoke-180s/` records the next stable 4096x2304 run:
  4,604/4,604 hardware-decoded frames, queue depth two, zero decoder faults,
  and continuous presentation for 180.12 seconds. Its software-decoded motion
  source limited the measured rate to 25.56/25.42 encoded/presented FPS, so it
  is retained as a stability pass and performance preflight failure.
- `profile-handoff-failure/` records the immediate `-5` startup rejection when
  the chained second run selected a composite custom-server target as a peer
  profile. The repaired Core keeps that target only in memory, uses the plain
  peer profile as its non-persisted baseline, and the wrapper filters composite
  targets. The one generated file was moved to a sanitized Trash path.

The target has passed 12/12 Swift tests against the ABI v2 Core dylib, the
focused Rust housekeeping test, and Release rebuilds with reference-aware
two-frame backpressure, control housekeeping, and peer-profile isolation.
These results and the successful 180-second diagnostics do not replace the
missing 4096x2304 1800-second acceptance run.

No peer ID, server address, server public key, password, token, or complete
authentication message is present in these files.

The remaining acceptance steps require a short post-fix live smoke followed by
the full run. The user sets the existing Mac mini
RustDesk password only in an interactive MBP shell, without sending it to
Codex or saving it in the repository:

```zsh
cd ~/rustdeskNativePhase2
read -s 'RDN_PASSWORD?RustDesk password: '
export RDN_PASSWORD
./Scripts/benchmark-live-from-rustdesk-config-mbp.sh \
  .build/release/RustDeskNative \
  Build/CoreBridge/x86_64/liblibrustdesk.dylib \
  1800 automatic \
  Benchmarks/phase2-live-1800s
unset RDN_PASSWORD
```

Only a successful run that persists real H265 framing, dimensions, hardware
decode, IOSurface/Metal presentation, bounded queues, and 30-minute stability
metrics can replace this incomplete marker. A successful command also writes
`phase2-live-1800s.validation.txt`, containing sample coverage, App/VTDecoder
CPU and RSS, steady RSS slope, early/late window growth and their enforced
limits.
