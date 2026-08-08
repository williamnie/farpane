# H2.2.14 ScreenCaptureKit idle-status fallback

Date: 2026-08-08

## Outcome

The macOS 13-compatible capture adapter now uses ScreenCaptureKit's explicit idle frame status as the bounded missing-dirty-metadata fallback required by §11.3. It can lower a genuinely unchanged route to the idle cadence without treating missing dirty rects as trusted or inspecting frame pixels.

## Production evidence and root cause

The follow-up H2.2.13 Mini session passed the strict H2.2.12 validator:

```text
duration: 359.565 seconds
records: 354 total, 352 periodic
codec: H.265, requested 30 FPS
capture / encode / Rust-admission median: 26.220 / 25.878 / 24.896 FPS
capture→encode / encode→Rust median absolute gap: 0.290 / 0.805 FPS
dirty metadata trusted: 0/352
content high-motion: 352/352
```

This also provides follow-up evidence for H2.2.13: 30/30 cadence rose from 47/97 (48.5%) in the original log to 277/352 (78.7%), while applied-moderate fell from 40/97 (41.2%) to 49/352 (13.9%). All 17 isolated periodic `2/3` queue runs and 23 of 26 two-sample runs had no encoded-queue cause; 23 three-sample runs each produced one cause. The log still contained sustained near-full occupancy and one real `3/3` sample, so remaining bounded pressure is not treated as a regression. Periodic log records and Rust diagnostic arrivals have independent timing, so their apparent ordinals are not used as an exact policy trace.

Host process CPU was 11.52% on average and 18.50% at maximum, physical-footprint peak was 46,613,728 bytes, thermal state was nominal for every available sample, and low-power mode stayed disabled on AC. This six-minute diagnostic is not the §15 600-second or 30-minute performance gate.

The session began before the H2.2.14 delivery artifact was built, so its 352/352 high-motion result is evidence for the missing fallback, not an acceptance result for this change.

The active adapter already parsed `SCFrameStatus`, but accepted only `.complete` and returned for every other value. The current Xcode SDK contract defines `.idle` as a sample where a new frame was not generated because the display did not change. Discarding it left no production fallback authority whenever `.dirtyRects` was absent.

This evidence supports connecting the documented status fallback. It does not prove that every macOS/display configuration emits repeated idle samples; that remains a real-build observation.

## Policy boundary

- `.idle` is the only non-complete status admitted as a motion observation;
- a full rolling window plus the existing minimum dwell is required before demotion;
- the resulting decision retains `dirtyMetadataTrusted=false`;
- a `.complete` frame with missing or invalid dirty metadata clears fallback samples and immediately restores fail-safe high-motion demand;
- `.blank`, `.suspended`, `.started` and `.stopped` remain ignored lifecycle signals;
- existing pressure ceilings, recovery hysteresis and configuration-update identity gates are unchanged.

Switching between dirty-rect and frame-status authority clears the motion window so samples from different evidence sources are not blended. There is no pixel readback, CPU hash/diff, new timer, raw-frame copy, Host ABI, wire, log-schema, Hermes, dependency, CI, database or root-configuration change.

## Verification

Focused tests cover:

- only `.idle` enters the fallback while every other `SCFrameStatus` keeps its existing disposition;
- three incomplete idle samples cannot demote a four-sample/two-second controller;
- the fourth eligible idle sample produces idle/3 FPS while metadata remains untrusted;
- a subsequent complete frame without dirty metadata immediately returns to high-motion/30 FPS;
- existing severe pressure remains authoritative during the fallback.

```text
swift test --filter HostCaptureCadenceTests
result: 16 passed, 0 failed

swift test --filter HostScreenCaptureTests
result: 4 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 122 passed, 0 failed; built Host core loaded and Host lifecycle passed 3/3

python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
result: 17 passed, 0 failed

swift build -c release --arch arm64
result: passed

RDN_HOST_GOLDEN_APP=".../FarPane.app" Scripts/preflight-host-mode-h1-golden.sh
result: H1_GOLDEN_PREFLIGHT_READY; patch reverse checks, stable signing,
latest executable/core UUID match, sanitized diagnostic and real
ScreenCaptureKit→hardware H.264 path passed
```

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808033459/FarPane-arm64-20260808033459.zip
SHA-256: 57ff1d29743270f14ebe205d9df4decf2ea135deda6eb97c6345e72c5b8cc127
```

The executable and bundled core are arm64. Stable Apple Development signing,
non-CDHash designated requirement, strict deep verification, ZIP integrity and
extracted-app signature/build-number/architecture verification passed.

## Remaining evidence

Install the next Mini build and run an uninterrupted static/continuous-motion/static route. The automatic live log must show whether:

1. static periods reach `content=idle`, `target/applied=3/3` while `dirtyMetadataTrusted=false`;
2. motion produces a complete frame and promptly restores high-motion/30 FPS;
3. H2.2.13 prevents transient `2/3` queue samples from recreating `30↔15` oscillation.

If static periods remain high-motion, that is evidence that this ScreenCaptureKit route does not emit usable idle callbacks; no CPU full-screen diff or guessed idle result should be added without a separate bounded design step.
