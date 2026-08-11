# H6.1d Viewer audio explicit-policy ABI contract

Date: 2026-08-11

## Outcome

Viewer ABI v17 now carries one immutable `receiveAudio` policy. It defaults to
disabled at the Swift product boundary and projects exactly to RustDesk's
existing `disable_audio` option before connection startup. Existing product
callers remain default-off.

## Contract evidence

- C, Swift, and Rust share the same ABI v17 Boolean in the same struct slot;
  Host ABI remains v18.
- `CoreConnectionConfig.receiveAudio` defaults to `false` and is independent of
  clipboard and file-transfer policy.
- Rust reads the policy before creating the connection epoch or worker, then
  maps `false` to `disable_audio=true` and `true` to
  `disable_audio=false` before login.
- Dedicated file-transfer sessions reject any desktop clipboard or audio
  capability, so the file path cannot implicitly open playback.
- RustDesk continues to own `OptionMessage.disable_audio`, `AudioFormat`,
  `AudioFrame`, Opus decoding, buffering, and native playback. No audio payload
  or protobuf ABI was added to Swift.
- The upstream client change is captured by a canonical patch; bootstrap and
  source verification require that patch and exact bridge synchronization.

The dedicated machine audit reports
`viewer-audio-abi-capable-product-default-off` with 12/12 evidence checks and
14/14 source anchors. The refreshed audio ownership audit reports
`host-opt-in-implemented-development-incomplete` with 12/12 established
evidence, 3/3 remaining gaps, and 16/16 source anchors.

## Verification

- RED regression initially failed because the H6.1d machine audit did not
  exist.
- Rust focused policy regression passed.
- Full Rust suite: 241/241 passed.
- Fresh arm64 release Core build passed and produced a Mach-O arm64 dylib.
- Full Swift suite loaded that Core: 1018/1018 passed.
- Full ScriptTests: 186/186 passed.
- Canonical and vendored bridge verification passed; the new client patch
  reverse-check passed.
- Isolated fresh arm64 Swift release build passed; the resulting executable is
  Mach-O arm64.
- Both audio machine audits and `git diff --check` passed.

## Not claimed

- Product Viewer audio remains disabled; no product opt-in is exposed.
- Remote audio permission is not yet projected or presented to the Viewer.
- No virtual audio input selector is implemented.
- No GUI was started, no app was installed, and no single-Mac or dual-Mac audio
  acceptance was run.
- Hermes, protobuf wire, CI, root dependencies, databases, and secrets were not
  changed.

## Next boundary

`viewer-audio-product-opt-in-permission-lifecycle`: expose an explicit Viewer
opt-in only when the remote permission/capability state permits it, while
preserving connection-scoped revocation and default-off behavior.
