# H2.2.16 VideoToolbox frame-context single ownership

Date: 2026-08-08

## Outcome

The Mini did not disconnect normally. FarPane build `20260808120005` crashed after 162.30 seconds of a live H.265 route. The same fault had already occurred in build `20260808092002`; both reports identify the same queue and product stack. The retained per-frame context could be consumed by a synchronous VideoToolbox callback and then released a second time by the submission path.

H.264 and H.265 now use one ownership rule: a non-`noErr` submission remains caller-owned and is released by the caller; a `noErr` submission transfers the context exclusively to the output callback. Accepted-frame drop handling also remains exclusively in that callback.

## Evidence

- Latest crash: `~/Library/Logs/DiagnosticReports/RustDeskNative-2026-08-08-121829.ips`
  - build `20260808120005`
  - `EXC_BAD_ACCESS`, `SIGSEGV`
  - faulting queue `io.farpane.host-raw-frame-handoff`
  - `_swift_release_dealloc → HostHEVCEncoder.encode → HostMediaPipeline.consume`
- Earlier same-signature crash: `~/Library/Logs/DiagnosticReports/RustDeskNative-2026-08-08-103841.ips`
  - build `20260808092002`
  - same exception, queue and product stack
- Live log: `~/Library/Logs/FarPane/HostMedia/host-media-live-2026-08-08T041532Z-9E5E8205-F56A-4DDF-86F5-25958730E4CE.jsonl`
  - H.265 route, 158 records, 157 periodic records, no final lifecycle
  - last runtime 162.2988595 seconds
  - last sample: encoded queue 3/3, 11 consecutive send drops, recent send-drop rate 0.9375, severe pressure
  - capture totals: 3,754 callbacks; complete 3,745; idle 9
  - complete-frame dirtyRects: unrecognized 3,745; all other classifications 0

The missing final lifecycle and matching macOS crash report make this a crash run, not a normal disconnect or a valid stability/performance acceptance run.

## Fix

`VTCompressionSessionEncodeFrame` may output synchronously before returning. The prior H.264/H.265 code passed a retained context as `sourceFrameRefcon`, consumed it with `takeRetainedValue` in the output callback, and also released it from the caller when the synchronous `infoFlagsOut` contained `FrameDropped`.

Both codecs now pass `nil` for caller-side `infoFlagsOut`. Only a non-`noErr` return releases the context in the caller. After `noErr`, the callback's status/info flags are the sole completion/drop authority and it consumes the retained context exactly once.

## Verification

- `MallocScribble=1 MallocPreScribble=1 swift test --filter HostHEVCEncoderTests/testRapidHardwareHEVCSubmissionKeepsFrameContextSingleOwner`
  - 2,000 rapid hardware HEVC submissions
  - 1 test passed, 0 failed, no skip
- H.264/H.265 encoder plus real ScreenCaptureKit pipeline suite under malloc scribble: 10 passed, 0 failed, no skip.
- Full built-core Swift package regression under malloc scribble: 127 passed, 0 failed.
- Script tests: 20 passed, 0 failed.
- `swift build -c release --arch arm64`: passed.
- Canonical Rust mirror, formatting, vendor diff and reverse-patch checks: passed.
- Golden preflight: `H1_GOLDEN_PREFLIGHT_READY`; stable non-CDHash signing, executable/core UUID matching, sanitized diagnostic and real ScreenCaptureKit to hardware H.264 path passed.

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808122922/FarPane-arm64-20260808122922.zip
SHA-256: 932ee65bc1e9ab082c8c82917ed9e8798568008e87c0df435d0ac2f824375dfc
```

ZIP integrity, extracted strict signing, build number, arm64 executable/core and current executable/core UUID matching passed. The intermediate `20260808121842` and `20260808122728` artifacts were moved to Trash so they cannot be mistaken for the final installable build.

A live Mini H.265 run longer than 162 seconds with a normal route final lifecycle remains required to close the real-device regression.
