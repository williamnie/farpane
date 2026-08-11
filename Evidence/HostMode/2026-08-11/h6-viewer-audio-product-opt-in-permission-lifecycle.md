# H6.1e Viewer audio product opt-in and permission lifecycle

Date: 2026-08-11

## Outcome

FarPane Viewer now exposes an explicit, default-off audio opt-in for the next
desktop connection. Viewer ABI v18 carries connection-scoped remote audio
permission metadata, and RustDesk admits audio format and frame processing only
while local opt-in, remote permission, and authentication are all active.

## Contract evidence

- The Home switch is ephemeral: it applies to the next desktop connection,
  resets immediately after startup, and does not persist to disk.
- A connection pins one immutable `receiveAudio` policy. Password retry and
  automatic recovery retain that exact policy; file-transfer sessions cannot
  enable desktop audio.
- C, Rust, and Swift share the same typed permission event with ABI version,
  connection epoch, permission kind, and enabled state. Epoch zero and unknown
  permission kinds fail closed.
- Rust emits the authoritative audio permission at authenticated connection
  startup and whenever it changes. Permission absence before authentication is
  never treated as playback authorization.
- RustDesk gates both `AudioFormat` and `AudioFrame` on
  `receiveAudio && remoteAudioEnabled && authenticated`. Revocation replaces
  the audio handler, dropping decoder and output state before later frames.
- Swift owns only permission and presentation state. Audio payloads, Opus
  decoding, buffering, and native playback remain entirely in the pinned Rust
  data plane.
- Viewer presentation distinguishes not enabled, awaiting permission,
  receiving, denied, revoked, and stopped states.
- The upstream changes are captured in a canonical patch required by bootstrap
  and source verification.

The dedicated machine audit reports
`viewer-audio-product-opt-in-permission-lifecycle-ready` with 14/14 evidence
checks and 16/16 source anchors. The refreshed audio ownership audit reports
13/13 established evidence, 2/2 remaining gaps, and 16/16 source anchors.

## Verification

- RED Swift regression initially failed because the typed permission event,
  session owner, and presentation policy did not exist.
- RED script regression initially failed because the H6.1e machine audit did
  not exist.
- Focused Swift session-owner suite: 4/4 passed.
- Focused Rust regression covering the local/remote/authenticated truth table
  and typed event: 1/1 passed.
- Fresh arm64 release Core build passed and produced a Mach-O arm64 dylib.
- Full Rust suite: 241/241 passed.
- Full Swift suite loaded that fresh Core: 1022/1022 passed.
- Full ScriptTests: 187/187 passed.
- Canonical and vendored source verification passed; the H6.1e patch
  reverse-check passed.
- Isolated fresh arm64 Swift release build passed; the resulting
  `RustDeskNative` executable is Mach-O arm64.
- H6.1e, H6.1d, and audio ownership machine audits plus `git diff --check`
  passed.

## Not claimed

- No virtual audio input selector is implemented.
- No GUI was started, no app was installed, and no single-Mac or dual-Mac audio
  acceptance was run.
- Actual remote audio playback, revocation, reconnection, and cross-machine
  performance remain unverified without a second Mac.
- Hermes, RustDesk protobuf wire, CI, root dependencies, databases, and secrets
  were not changed.

## Next boundary

`virtual-audio-input-selection`: add an explicit, bounded Host product owner
for selecting a virtual input device while preserving system-default microphone
behavior and the existing RustDesk audio wire.
