# RustDesk Native Viewer

This repository implements the [`docs/architecture.md`](docs/architecture.md)
Phase 0/1 video pipeline, the
accepted Phase 2 RustDesk Core Bridge, and the Phase 3 input/viewer surface.
The macOS 13+ AppKit viewer can drive fixed HEVC fixtures through
VideoToolbox hardware decode into NV12 IOSurface-backed `CVPixelBuffer`s, maps
the Y/UV planes with `CVMetalTextureCache`, converts BT.709 YUV to RGB in a
Metal shader and presents through `MTKView`. Live mode loads a narrow C ABI
facade built from pinned RustDesk 1.4.9 and routes compressed H265 packets into
the same decoder without copying decoded RGBA frames.

Connection, rendezvous/relay, authentication, encryption and the wire protocol
remain in RustDesk's Rust core. The Swift layer exposes only connection state,
sanitized metrics and copied encoded packet bytes. There is no CPU-side
full-frame RGBA conversion or fallback path.

Phase 3 adds aspect-fit/Retina coordinate mapping, mouse buttons and drag,
discrete/precise wheel input, basic keyboard events, key repeat, common
modifiers and AppKit-committed UTF-8 text through ABI v5. Standard-mode IME
composition stays local; only committed text crosses the boundary through
RustDesk Core. Exclusive mode sends macOS physical key positions through the
pinned Core's keyboard-map path so the remote input method owns composition.
The AppKit shell currently provides a single-profile connection form, sanitized
state and error text, full-screen control, a performance HUD and an explicit manual
remote-feedback checklist. Pointer and keyboard events remain semantic at the
C ABI; the pinned RustDesk Core constructs and sends the actual protocol
messages after the remote grants control permission.

## Build and test

```sh
swift test
xcodebuild -scheme RustDeskNative \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 build
Scripts/build-universal.sh
```

The last command requires one Apple Development signing identity and produces a
stable-identity universal app at `Build/RustDeskNative.app`. Both arm64 and
x86_64 Core libraries must be present. Install it at the fixed per-user path:

```sh
Scripts/install-local-macos.sh
```

The installed product is `~/Applications/RustDesk Native Viewer.app`. Rebuilds
change the code hash and build number but retain the same bundle identifier,
Team ID and designated requirement, so Accessibility and Input Monitoring
permissions remain attached to the product identity. Ad-hoc signing is allowed
only for non-TCC development with `RDN_ALLOW_ADHOC_SIGNING=1` and is rejected by
the installer because its CDHash-bound identity would require authorization
again after every rebuild.

Launching the installed app without arguments opens the connection form. The
product UI accepts a RustDesk ID server, server public key, device ID and an
optional force-relay mode; RustDesk Core discovers the actual relay in the
normal self-hosted configuration. The bundled Core path is intentionally not a
user-facing setting. The operator may save the non-password connection profile
locally or clear it from the form. The password field is cleared after
connection and is never persisted. Automated benchmark
mode takes connection values from named environment variables and immediately
removes them from the App process environment; peer/server/key material is not
placed in command arguments or logs.

## Build the RustDesk Core

The source/bootstrap scripts verify the RustDesk 1.4.9 commit, apply the
tracked patch, install pinned vcpkg dependencies and build a native-architecture
`cdylib`:

```sh
Scripts/build-rust-core.sh
```

Generated RustDesk/vcpkg sources and compiled outputs stay under ignored
`Vendor/` and `Build/` directories. The distributable patch, bridge source,
AGPL license and modification notice remain tracked.

On the Intel MBP, set the existing RustDesk password only in the current shell
and run the config-aware acceptance wrapper. It reads the existing Hermes and
peer settings without printing them, requires at least 1800 seconds, and unsets
the password from the App process immediately after reading it:

```zsh
cd ~/rustdeskNativePhase2
read -s 'RDN_PASSWORD?RustDesk password: '
export RDN_PASSWORD
Scripts/benchmark-live-from-rustdesk-config-mbp.sh \
  .build/release/RustDeskNative \
  Build/CoreBridge/x86_64/liblibrustdesk.dylib \
  1800 automatic \
  Benchmarks/phase2-live-1800s
unset RDN_PASSWORD
```

For the formal 4096x2304/30 Hz performance scene, first select the Mac mini's
`2048x1152` HiDPI mode (not `2048x1152 (low resolution)`), verify that
`system_profiler SPDisplaysDataType` reports a 4096x2304 framebuffer, and run
the GPU-driven motion source on the Mac mini. It compiles locally, prevents
display sleep, and exits automatically after the requested duration:

```zsh
Scripts/run-phase2-motion.sh 2100
```

The motion source uses Metal and does not decode a competing video,
so it exercises RustDesk's real 4K/30 FPS capture path without consuming the
sender CPU needed by the encoder.

With the motion source running and `RDN_PASSWORD` exported in the existing
Intel MBP shell, the guarded preflight-plus-acceptance sequence is:

```zsh
Scripts/run-phase2-acceptance-mbp.sh
```

The script refuses non-Intel execution and refuses to overwrite any prior raw
benchmark artifact. It runs a strict 60-second 4096x2304/28 FPS preflight,
waits five seconds for session cleanup, and only then starts the 1800-second
acceptance run. It pins the accepted secure Hermes relay path because a direct
transport reset was observed during diagnosis; direct mode remains available
through the lower-level benchmark wrapper for targeted investigation.

Do not put the password in a command argument, repository file, log, or chat.
The live acceptance command also fails closed unless it observes real H265
packets, a single verified Annex-B or 4-byte AVCC framing mode, VPS/SPS/PPS and
keyframes, nonzero remote encoded dimensions and measured encoded-frame FPS,
matching decoded dimensions, a nonzero drawable, hardware NV12/IOSurface
output, bounded queues, network telemetry and decode/render timing. Its
validation rejects three seconds or more of presentation staleness while
encoded packets continue arriving, including any final encoded-to-presented
lag. A full acceptance run additionally requires real 4096x2304 input,
at least 28 encoded and presented FPS, a maximum queue depth of two, average
App CPU no more than 60%, average VTDecoder CPU no more than 10%, less than
1 MiB/min steady-state RSS slope, and less than 50 MiB growth between the first
and last five-minute steady windows. The summary retains the raw one-second
App/VTDecoder CPU and RSS samples.
For diagnosis only, `RDN_PHASE2_SMOKE=1` permits a shorter duration while
retaining live codec, framing, dimensions, hardware decode, recovery and frame
presentation-ratio gates; it never qualifies as Phase 2 acceptance.
Set `RDN_FORCE_RELAY=1` for a deliberate Hermes-relay diagnostic or acceptance
run; the low-level wrapper otherwise retains RustDesk's automatic direct/relay
choice.

Live HEVC backpressure is reference-aware: the decoder keeps a bounded
two-frame queue, but never silently drops an arbitrary RustDesk picture. If
the queue fills, it first drains VideoToolbox's asynchronous work and records
the wait; only an actual drain/decode failure resets that decoder generation
and asks the Rust core to send a fresh keyframe. Reports persist
`backpressureWaits`, `maxBackpressureWaitMS`, `referenceFrameDrops`,
`decoderResets`, `keyframeRequests`, and the first/last sanitized VideoToolbox
status so a recovery cannot masquerade as uninterrupted presentation.

## Phase 3 acceptance

Build the matching Core and Release viewer on the Intel MBP, set the password only
in its current interactive shell, and launch the Viewer once without arguments
to verify that an incomplete form produces only the sanitized local error. Then
close it, start the GPU motion source on the Mac mini, and run:

```zsh
Scripts/run-phase3-acceptance-mbp.sh
```

The guarded run lasts at least 1,800 seconds over the configured secure Hermes
relay and retains all Phase 2 video/performance/stability gates. During the run,
the operator must exercise click, drag, scroll, English and locally composed
Chinese text, key repeat, a modifier shortcut,
full-screen enter/exit and HUD hide/show, observe the real remote feedback, and
record only personally verified results through `验收记录`. The post-validator
requires balanced button/key events, zero Core input rejections, a remote
`controlReady` permission state and a complete manual-feedback checklist. Only
after both the retained pipeline gates and functional validator pass does the
script create `Evidence/IntelMBP/<date>/Phase3/` with the report, raw one-second
samples, sanitized App log, validation summaries, environment/build hashes and
a verified `SHA256SUMS` manifest; it refuses to overwrite existing evidence.

Local tests, fixture playback, a short smoke, or event counters without observed
remote feedback do not qualify as Phase 3 completion.

The accepted Intel baseline completed on 2026-08-03 after the MBP's active AWDL
interface was disabled to eliminate periodic Wi-Fi stalls. It ran for 1800.081
seconds at 4096x2304 H265, presented 59,843/60,234 frames, passed all nine
operator-confirmed functional checks and all retained performance/stability
gates. The authoritative sanitized artifacts and verified checksums are under
`Evidence/IntelMBP/2026-08-03/Phase3/`.

The separate productization acceptance script checks that `awdl0` is already
down before starting its 30-minute latency/stability run. It never changes the
interface itself; restore AWDL after the run if AirDrop or peer-to-peer Apple
features are needed.

### Exclusive remote keyboard follow-up

The Viewer also provides an explicit `独占键盘` mode for macOS-reserved
shortcuts such as Command-Space and Command-Tab. Standard mode remains the
default and keeps AppKit IME composition local. Exclusive mode installs an
active session event tap, suppresses supported local key events and forwards
physical key-position events through ABI v5, so the remote Mac owns shortcut
and input-source/IME handling. It requires both Accessibility and Input Monitoring
permission. Passwords, key content and complete input messages are not logged.

Press `Control-Option-Shift-Escape` to leave exclusive mode. When the
window/app temporarily loses focus, the Viewer fails open and releases captured
remote keys; returning to the Viewer automatically restores exclusive mode if
the user had explicitly enabled it. Manual exit, the escape chord, loss of
connection control, permission failure, or a disabled event tap clears that
restore intent.
Unsupported media and hardware keys remain local. Touch ID, the power button
and secure-input fields are outside this mode's guarantee.

After permissions are granted, the dedicated three-minute real-link check is:

```zsh
Scripts/run-exclusive-keyboard-preflight-mbp.sh
```

Grant both permissions to the fixed installed bundle path
`~/Applications/RustDesk Native Viewer.app`; the preflight deliberately
launches that stable-identity bundle rather than the transient `.build` path.

The first permission-grant launch is diagnostic only; close and rerun it after
granting permission. This follow-up does not alter or replace the already
accepted Phase 3 evidence. Installed build `2026080306` passed the clean Intel
real-link preflight, including remote shortcuts and IME input, automatic restore
after temporary focus loss, balanced key events and the local escape chord.

The final productization evidence combines a 1,800-second daily-operation run,
a focused current-resolution/full-screen/HUD supplement and a 4096x2304
preflight of the identical final viewer/Core hashes. It also proves that a
different signed build retained the same designated requirement without a
repeated TCC grant. The composite validator explicitly retains the original
single-run fixed-resolution gate failure instead of presenting it as a clean
4096x2304 run. Sanitized artifacts and verified checksums are under
`Evidence/IntelMBP/2026-08-03/Productization/`.

## Generate fixtures

```sh
Scripts/generate-fixtures.sh
```

The generated `.hevc` files are intentionally ignored. Their checked-in
`ffprobe` metadata and SHA-256 sidecars make the inputs auditable. See
`Fixtures/README.md`.

## Run a benchmark

```sh
Scripts/benchmark-mbp.sh \
  Build/RustDeskNative.app \
  Fixtures/hevc-4096x2304-30.hevc \
  4096 2304 600 high-performance \
  Benchmarks/intel-fullscreen-4k
```

The benchmark uses a borderless full-screen window, samples process CPU/RSS at
a nominal one-second interval, writes raw samples to CSV, and asks the app to
write decode/render counters and latency statistics to JSON. It fails when the
decoded dimensions, hardware-decode status, NV12 format, IOSurface backing or
decode-error invariants do not hold.

Fresh Intel MBP results and limitations are recorded in
[`docs/benchmark-results.md`](docs/benchmark-results.md). The authoritative
Phase 2 artifacts, sanitized logs,
raw samples, independent validation and SHA-256 manifests are under
`Evidence/IntelMBP/2026-08-03/Phase2/`.

## Documentation

The documentation index is [`docs/README.md`](docs/README.md). In particular,
the approved implementation baseline remains in
[`docs/architecture.md`](docs/architecture.md), while the proposed multi-device,
Keychain quick-connect and floating session-controller page work is specified in
[`docs/product-ui-design.md`](docs/product-ui-design.md).
