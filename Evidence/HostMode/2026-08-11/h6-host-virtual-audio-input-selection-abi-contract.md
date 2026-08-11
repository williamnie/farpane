# H6.1f Host virtual audio input selection ABI contract

Date: 2026-08-11

## Outcome

Host ABI v19 now carries one immutable optional audio input-device name. Empty
selection remains the only representation of the system-default microphone;
an explicit selection is accepted only with Host audio enabled and cannot
silently fall back if the named device is unavailable.

## Contract evidence

- C, Rust, and Swift carry the same copied optional UTF-8 device name.
- An explicit name is limited to 512 UTF-8 bytes and rejects surrounding
  whitespace and control characters. A disabled audio policy rejects any
  non-empty name.
- Rust persists `audio-input` before Host identity/runtime creation and start
  preflight requires exact readback. Empty/default selection is represented by
  the absence of the persisted option, matching pinned Config semantics.
- Under `rdn-native-host`, the pinned cpal audio service requires exactly one
  matching device for a non-empty request. Missing or ambiguous names return
  an error; only an empty request may use the default input.
- The upstream behavior is captured by a canonical patch required by bootstrap
  and source verification.
- Existing App, Agent, and bootstrap callers do not supply a device name, so
  product behavior remains the default microphone until the next product
  selection boundary.
- Audio payloads, Opus encoding, and RustDesk `AudioFormat`/`AudioFrame` wire
  remain entirely in Rust.

The H6.1f machine audit reports
`host-virtual-audio-input-abi-capable-product-default-microphone` with 12/12
evidence checks and 14/14 source anchors. The refreshed audio ownership audit
reports 14/14 established evidence, 2/2 remaining gaps, and 19/19 source
anchors.

## Verification

- RED Swift regression failed because `audioInputDeviceName` did not exist.
- RED script regression failed because the H6.1f machine audit did not exist.
- Focused Rust device policy and fallback regressions: 2/2 passed.
- Focused Rust storage readback suite: 5/5 passed.
- Fresh Host ABI lifecycle and raw C layout suite: 4/4 passed.
- Full Rust suite: 243/243 passed. One preceding run observed the existing
  cursor-change race; its focused rerun and the complete rerun both passed.
- Full Swift suite loaded the ABI v19 Core: 1023/1023 passed.
- Full ScriptTests: 188/188 passed.
- Fresh arm64 release Core build passed and produced a Mach-O arm64 dylib.
- Isolated fresh arm64 Swift release build passed; the resulting
  `RustDeskNative` executable is Mach-O arm64.
- Canonical/vendor source verification, patch reverse-check, all three audio
  audits, and `git diff --check` passed.

## Not claimed

- No input-device enumeration, bootstrap field, Home selector, or product
  selection is implemented yet.
- No real audio device was enumerated or opened, and no TCC prompt was
  triggered.
- No GUI was started, no app was installed, and no single-Mac or dual-Mac
  audio acceptance was run.
- Hermes, RustDesk protobuf wire, CI, root dependencies, databases, and secrets
  were not changed.

## Next boundary

`host-audio-bootstrap-virtual-input-selection-contract`: add a strict
versioned bootstrap representation and explicit Home product selection while
preserving default microphone behavior and fail-closed device drift.
