# Phase 0/1 benchmark evidence

Date: 2026-08-02 (Asia/Shanghai)

## Environment

- Development: Apple Silicon Mac mini, macOS 15.7.7, Xcode 26.3,
  Swift 6.2.4.
- Acceptance: MacBook Pro 16-inch 2019, Intel i7-9750H, macOS 13.7.8,
  Xcode 15.2, Swift 5.9.2.
- Acceptance GPUs: Intel UHD Graphics 630 and AMD Radeon Pro 5300M.
- App target: macOS 13.0; built as an ad-hoc-signed universal `arm64 x86_64`
  app on both machines.
- External sampling: nominal one-second `ps` samples. VideoToolbox did not
  expose a separately visible `VTDecoderXPCService` during these fixture runs;
  hardware decode is instead verified by requiring a hardware decoder when the
  session is created and recording
  `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder=true`.

## Audited inputs

Both fixtures are HEVC Main, 8-bit 4:2:0 video-range BT.709 Annex-B streams,
60 frames long, with AUD units and 30 Hz SPS timing. They are looped from an IDR
for the benchmark duration.

| Fixture | `ffprobe` dimensions | Rate | SHA-256 |
| --- | ---: | ---: | --- |
| `hevc-2048x1152-30.hevc` | 2048x1152 | 30/1 | `b5d448aed5e2fe01fe0cb3d4241fbe7ae02b3719e0ff6dbb9e785ec0c333ca2b` |
| `hevc-4096x2304-30.hevc` | 4096x2304 | 30/1 | `08ed68fd5e6626932d6cdc0357dcdf81da4e1b8e0c73b8c33a754886fe94e23a` |

## Results

All runs are real AppKit GUI runs on the Intel MBP. `CPU` is the app's process
CPU time divided by wall time, where 100% is one logical core. Initial-to-final
memory growth includes creation of the decoder/surface pools; steady-state
growth uses the first sample after five seconds as its baseline.

| Input / local drawable | GPU | Duration | CPU | FPS | Dropped | Queue max | Decode avg / P95 | Render avg / P95 | Memory final / peak growth | Steady growth |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4096x2304 / **4096x2560 full-screen** | Radeon Pro 5300M | 600.013s | 5.90% | 28.971 | 617 | 2 | 10.188 / 13.021 ms | 5.637 / 7.539 ms | 41.98 / 42.12 MB | 0.69 MB |
| 4096x2304 / 2560x1440 window | Radeon Pro 5300M | 600.019s | 4.44% | 29.984 | 9 | 2 | 13.864 / 14.894 ms | 4.377 / 6.399 ms | 26.20 / 44.94 MB | -18.43 MB |
| 4096x2304 / 2560x1440 window | Intel UHD 630 | 600.004s | 3.33% | 28.845 | 693 | 2 | 13.164 / 14.811 ms | 3.523 / 3.943 ms | 26.27 / 44.96 MB | -18.38 MB |
| 2048x1152 / 2560x1440 window | Intel UHD 630 | 600.020s | 3.34% | 29.971 | 17 | 2 | 4.205 / 4.597 ms | 3.796 / 4.149 ms | 21.96 / 23.66 MB | -1.53 MB |

Every run recorded:

- `hardwareDecodeActive=true` and `hardwareDecodeRequired=true`;
- the decoded dimensions exactly matching the audited fixture;
- zero decode errors, zero non-NV12 frames and zero missing-IOSurface frames;
- `cpuRGBAFallback=false`;
- one uninterrupted 600-second process lifetime.

Raw app reports, nominal one-second CPU/RSS samples and app logs are under
`Evidence/IntelMBP/2026-08-02/`.

## Acceptance and interpretation

The full-screen 4K run meets every Phase 1 minimum measured here: CPU <=60%,
memory growth <=50 MB, FPS >=28, queue depth <=2 and ten minutes without a
crash. It does not meet the ideal 29.5 FPS target; 617 newest-wins frame drops
remain a Phase 2 pacing/real-stream investigation item.

The windowed A/B shows a real trade-off: UHD 630 uses less CPU, while Radeon
produces much smoother 30 FPS cadence. The prototype keeps an explicit GPU
switch. `automatic` remains conservative (low-power first) until a comparable
full-screen UHD power/thermal run is available; the core 4K acceptance command
uses `high-performance` explicitly.

The official RustDesk 1.4.9 measurements in `DESIGN.md` were a real networked
desktop session (about 103%-119% CPU at 4096x2304), while this prototype uses a
fixed synthetic fixture and has no RustDesk Core/network/input work. The results
therefore prove the native VideoToolbox/IOSurface/Metal pipeline and eliminate
the suspected CPU full-frame RGBA path, but they are not an apples-to-apples
end-to-end RustDesk speedup claim. The RustDesk Core Bridge remains out of scope
until Phase 2. The comparison remains the Phase 1 fixture baseline and is not
retroactively treated as Phase 2 end-to-end evidence.

## Phase 2 live acceptance

The pinned RustDesk 1.4.9 Core Bridge, C ABI loader, Annex-B/4-byte AVCC packet
validation, live parameter-set/keyframe handling and live benchmark telemetry
are implemented. Fresh target-machine verification established:

- RustDesk Core release build on macOS 13.7.8 x86_64 with Rust 1.82 and Xcode
  15.2 (`minos 13.0`), exporting the seven required ABI v2 `rdn_*` symbols,
  including the keyframe-request recovery entry point;
- 13/13 Swift tests on the Intel MBP, including loading the real Core dylib,
  checking ABI plus pinned upstream commit, and validating measured encoded
  frame/recovery diagnostics;
- a real Hermes transport attempt reaching `transportReady` with a measured
  26 ms delay, with no peer/server/key/authentication material written to the
  evidence files.

After the initial `passwordRequired` diagnostic, a credentialed 1800-second
Hermes-to-Mac-mini run authenticated and received 46,465 real Annex-B H265
packets at 2048x1152 with no packet sequence gaps. It is intentionally retained
under `Evidence/IntelMBP/2026-08-02/Phase2/freeze-reproduction-1800s/` as failed
evidence: only 1,760 frames were presented and VideoToolbox reported 44,680
decode errors. Sanitized system diagnostics identified
`kVTVideoDecoderReferenceMissingErr` (`-17694`): the former two-frame live
queue silently discarded an HEVC reference picture, poisoning subsequent
dependent pictures until another client reconnect forced a new keyframe.

ABI v2 now exposes RustDesk's existing video-refresh request. Live decoding
uses a bounded two-frame queue and drains VideoToolbox backpressure instead of
silently dropping a reference picture; only a true drain/decode failure resets
the decoder and requests a fresh keyframe. Rust-side housekeeping also sends
the existing RustDesk `TestDelay(from_client=true)` control message every five
seconds so the client-to-server half-path remains live. The fixed sources pass
12/12 Swift tests against the real Intel Core dylib, a dedicated Rust
housekeeping-message unit test, and a Release rebuild on the target.

The first post-housekeeping authenticated smoke then ran for the requested
180.08 seconds over a secure direct connection. It hardware-decoded all 4,780
real Annex-B H265 frames, presented 4,752, kept queue depth at two, and recorded
zero decode errors, reference drops, resets, packet gaps, or final
encoded-to-presentation staleness. This proves the observed freeze and 29/60/
131-second disconnect pattern is repaired, but the run remains diagnostic-only:
the Mac mini was accidentally using `2048x1152 (low resolution)`, so it cannot
qualify as the required 4K acceptance evidence.

After switching the Mac mini to the true HiDPI mode, the next smoke held the
real 4096x2304 stream for 180.12 seconds with 4,604/4,604 hardware decodes,
4,579 presentations, queue depth two, and no decoder fault. Its software-
decoded 4K motion source competed with the sender and limited the encoded rate
to 25.56 FPS, so it is retained as a stability pass and performance preflight
failure. `Scripts/run-phase2-motion.sh` now provides an automatically bounded,
GPU-driven Metal source for the final >=28 FPS run.

The final secure-relay run passed every Phase 2 gate. It continuously received
the real Mac mini 4096x2304 HiDPI desktop for 1800.142 seconds, observed H265
Annex-B plus VPS/SPS/PPS and IDR semantics, hardware-decoded all 54,721 encoded
frames, and presented 53,329 frames (97.456%). Active-stream encoded/presented
rates were 30.403/29.633 FPS. Decode average/P95 was 11.915/12.207 ms and render
average/P95 was 9.151/9.408 ms. Decoder and renderer queues both remained at
the bounded depth of two, with zero decode errors, reference drops, decoder
resets, keyframe requests, packet gaps, non-NV12 output, or missing IOSurfaces.

The 1,801 one-second samples cover elapsed seconds 0 through 1800. Average App
CPU was 5.020%, peak RSS was 22.000 MB, steady RSS slope was 0.056203 MB/min,
and early-to-late steady-window growth was 1.141 MB. The accepted transport was
the configured secure Hermes relay; a direct transport reset seen during
diagnosis is not represented as accepted evidence. Phase 2 is complete on this
baseline. The authoritative report, samples, sanitized log, independent gate
output, build/test logs, environment record and SHA-256 manifests are under
`Evidence/IntelMBP/2026-08-03/Phase2/`.

## Phase 3 implementation status

ABI v4, aspect-fit/Retina mapping, AppKit text input and committed UTF-8,
bounded precise scrolling, balanced key repeat, connection/error UI,
full-screen control, performance HUD, functional evidence counters and the
manual remote-feedback checklist are implemented. Local Swift and pinned-Core
tests are necessary implementation gates only; they are not live acceptance.
On the Apple Silicon development machine, the current local baseline passes 23/23
Swift tests (including loading the rebuilt ABI v4 Core), 9/9 focused Rust bridge
tests, a signed universal `x86_64 arm64` Viewer build and a hardware
VideoToolbox/NV12/Metal fixture smoke with bounded 1/2 decoder/renderer queues
and zero decode errors.

The final Phase 3 secure-relay run passed every retained pipeline and functional
gate. After disabling the Intel MBP's active AWDL interface to remove periodic
150ms Wi-Fi stalls, the Viewer operated the real 4096x2304 Mac mini for
1800.081 seconds without the official RustDesk controller. It hardware-decoded
all 60,234 Annex-B H265 frames and presented 59,843 (99.351%) at active-stream
rates of 33.499/33.284 FPS. Decode average/P95 was 10.400/12.087ms and render
average/P95 was 7.946/9.275ms. Both queues remained bounded at two with zero
decode errors, reference drops, resets, keyframe requests, packet gaps,
non-NV12 frames or missing IOSurfaces.

The 1,801 one-second samples recorded 7.560% average App CPU, 53.688MB sampled
peak RSS, a 0.093540MB/min steady RSS slope and 1.704MB early-to-late steady
window growth. The report's conservative internal peak was 54.949MB. Remote
feedback was confirmed for click, drag, scroll, English/Chinese text, held-key
repeat, a modifier shortcut, full-screen, HUD and sanitized error UI. It
recorded 2,129 pointer moves, 26/26 button events, 304 scroll events, 377/377
key events and zero rejected input events. Phase 3 is complete on this baseline;
the authoritative artifacts and verified manifest are under
`Evidence/IntelMBP/2026-08-03/Phase3/`.

## Exclusive keyboard follow-up status

An opt-in session event tap now captures supported keyboard events before the
local macOS shortcut handler and forwards semantic keys through the unchanged
ABI v4 boundary. Standard AppKit/local-IME behavior remains the default. The
exclusive path has a dedicated state machine for the
Control-Option-Shift-Escape exit chord and releases held remote keys on manual
exit, focus loss, connection loss or event-tap failure. It records activation
and failure counters without recording key content.

The Apple Silicon development baseline passes all 29 Swift tests (the optional
built-Core test also passes when pointed at the local arm64 ABI v4 library),
and the Release build succeeds. These local results do not prove that macOS
actually intercepts Command-Space or Command-Tab. A clean Intel MBP run through
Hermes with Accessibility and Input Monitoring permission is still required;
the retained Phase 3 acceptance artifacts are unchanged.
