# H6.1c Host audio bootstrap and microphone opt-in contract

Date: 2026-08-11

## Outcome

Host audio now has one default-off product policy across the foreground legacy
Host and background HostAgent. Immutable bootstrap schema v6 carries the exact
audio Boolean, schema v1-v5 migrates it to disabled, and the Home switch can
enable it only after the foreground App observes authoritative microphone TCC
authorization.

## Contract evidence

- `HostAgentAudioPolicy.disabled` is the default for builder, publication, and
  product integration. Audio policy changes participate in canonical document
  equality and advance `configRevision`; numeric Boolean aliases, extra keys,
  and future schemas fail closed.
- Home labels the control `远程音频（默认关闭）` and exposes the current
  microphone authorization state. Policy mutation requires Host off, no Viewer
  connection attempt, and no authorization request in flight.
- Only the foreground App user action can call the AVFoundation authorization
  request. The authorization owner admits only one not-determined request and
  re-reads TCC after completion instead of trusting the callback Boolean.
- HostAgent never requests authorization. It intersects the validated bootstrap
  opt-in with a non-prompting live authorization check before projecting Host
  ABI v18. Legacy Host uses the same effective product policy.
- `NSMicrophoneUsageDescription` is present while the existing
  `RustDeskNative` executable and `io.rustdesknative.viewer` bundle identity are
  preserved, so this step does not create a second TCC identity.
- Viewer receive audio remains unavailable and default-off; virtual input
  selection is not represented by this boundary.

The dedicated machine audit reports
`host-audio-bootstrap-microphone-opt-in-ready` with 13/13 evidence checks and
16/16 source anchors. The refreshed ownership audit reports
`host-opt-in-implemented-development-incomplete` with 12/12 established
evidence, 4/4 remaining gaps, and 16/16 source anchors.

## Verification

- RED regression initially failed because the H6.1c machine audit did not
  exist.
- Focused Swift regressions: 49/49 passed.
- Full Swift suite loaded the arm64 release Core: 1017/1017 passed.
- Full ScriptTests: 185/185 passed.
- Both audio machine audits and the four older bootstrap policy audits passed.
- `App/Info.plist` passed `plutil -lint`.
- Isolated fresh arm64 Swift release build passed; the resulting executable is
  arm64 and links AVFoundation.
- `git diff --check` passed.

## Not claimed

- Viewer ABI remains v16 and native Viewer audio reception remains disabled.
- No virtual audio input selector is implemented; system audio remains outside
  this microphone-only product boundary.
- No GUI was started and no microphone prompt or TCC mutation was triggered.
- No app was installed and no single-Mac or dual-Mac audio acceptance was run.
- Hermes, protobuf wire, CI, root dependencies, databases, and secrets were not
  changed.

## Next boundary

`viewer-audio-explicit-policy-abi-contract`: add an immutable, default-off
Viewer receive-audio policy without changing the RustDesk wire or implicitly
opening playback.
