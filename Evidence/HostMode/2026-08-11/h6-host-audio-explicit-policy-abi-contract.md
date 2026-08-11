# H6.1b Host audio explicit-policy ABI contract

Date: 2026-08-11

## Outcome

Host audio is now representable through Host ABI v18 while remaining product
default-off. `RdnHostCreateOptions.enable_audio` is immutable for one Host
lifetime, Swift defaults it to `false`, Rust persists and reads back the exact
`enable-audio=Y/N` value before accepting Host start, and the local approval
request intersects the Host policy with the remote peer's disable-audio option.

## Contract evidence

- C, Swift, and Rust agree on Host ABI v18 and the dedicated audio Boolean.
- Existing App and HostAgent callers do not pass `audioEnabled: true`; this ABI
  step cannot silently activate capture.
- Clipboard, audio, and file-transfer persistence remain independent and are
  verified by exact startup readback.
- `hearSystemAudio` is requested only when local audio is enabled and the peer
  has not disabled audio. The existing connection permission and audio service
  subscription continue to consume the same pinned RustDesk option.
- The canonical Host bridge equals the vendored source. The approval change is
  carried by a tracked patch and checked by bootstrap/source verification.
- Release features remain `rdn-native-core,rdn-native-host`; ScreenCaptureKit
  loopback is not enabled. Capture, Opus, playback, and wire payloads stay in
  the pinned RustDesk data plane.

The machine audit reports
`host-audio-abi-capable-product-default-off` with 16/16 evidence checks and
12/12 source anchors. The updated ownership audit reports
`host-policy-implemented-development-incomplete` with 11/11 established
evidence, 6/6 remaining gaps, and 14/14 anchors.

## Verification

- RED regression initially failed because the H6.1b audit did not exist.
- Focused Rust regressions: 3/3 passed.
- Full pinned Rust library suite with Host features: 241/241 passed.
- Fresh arm64 Release Core build: passed; the dylib exports
  `_rdn_host_abi_version`.
- Full Swift suite loaded that fresh Core: 1008/1008 passed.
- Full ScriptTests: 184/184 passed.
- Isolated fresh arm64 Swift release build: passed.
- Canonical patch reverse-check, pinned source verifier, Python compile, and
  `git diff --check`: passed.

## Not claimed

- No Host Home/bootstrap audio opt-in exists yet.
- `NSMicrophoneUsageDescription` and microphone TCC preflight/request are not
  implemented in this step.
- Viewer ABI remains v16 and native Viewer audio reception remains disabled.
- No virtual input selector, installation, single-Mac GUI smoke, or dual-Mac
  audio/performance/interoperability acceptance was performed.
- Hermes, protobuf wire, CI, root dependencies, and databases were not changed.

## Next boundary

`host-audio-bootstrap-microphone-opt-in-contract`: define the default-off
product policy and microphone authorization projection without enabling Viewer
audio reception or system-audio loopback.
