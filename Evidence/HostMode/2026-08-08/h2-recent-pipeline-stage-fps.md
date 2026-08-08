# H2.2.9 bounded recent pipeline-stage FPS diagnostic

Date: 2026-08-08

## Outcome

The local Host card now reports distinct five-second rates for capture completion, encoded access units and successful Rust production-queue admission. This narrows the reported 8.3–12 FPS observation without changing cadence policy or claiming a performance fix.

## Production boundaries

- capture: complete ScreenCaptureKit frames accepted by `HostMediaTelemetry.recordCapturedFrame`;
- encode: VideoToolbox access units reaching `recordPacket`;
- Rust admission: `rdn_host_media_submit_access_unit` returning success and recording `sendAccepted`.

Rust admission is only queue acceptance. It is not encrypted writer completion, network delivery, remote decode or presentation acknowledgement.

Each stage owns a bounded ring of at most 1,202 monotonic timestamps and uses the same trailing five-second calculation. A stage with fewer than two current events or no event remaining in the window reports zero rather than a stale value. The three rings contain timestamps only; no pixels, encoded payload, dirty-rect coordinates, peer/server metadata, address, credential, key or raw error is stored.

No Host ABI, wire protocol, serialized evidence schema, dependency, cadence policy or Hermes configuration changes.

## Interpretation

- capture lower than target/applied: inspect ScreenCaptureKit delivery/configuration and cadence classification;
- capture high, encode low: inspect raw-frame handoff, encoder backpressure and VideoToolbox callbacks;
- encode high, Rust admission low: inspect C ABI queue backpressure and drop ledger;
- all three high while Viewer remains low: continue through Rust writer, network, remote decode and presentation.

## Verification

The deterministic stage-rate test injects capture/encode/Rust-admission timelines at 30/25/20 FPS, verifies all three distinct values, advances the clock six seconds without events and requires all recent values to decay to zero.

```text
swift test --filter HostMediaTelemetryTests
result: 13 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 115 passed, 0 failed; built Host core loaded and Host lifecycle passed 3/3

swift build -c release
result: passed
```

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808105325/FarPane-arm64-20260808105325.zip
SHA-256: 1d733000390b9499b84b1a555265fe3acee33f269a01533033579115c3fd1ed0
```

The executable and bundled core are arm64. Stable Apple Development signing, strict deep verification, ZIP integrity, extracted-app signature/build-number/architecture verification and a credential-like filename scan all passed.

## Remaining evidence

Install the new arm64 build on the Mini. Record the complete two-line Host diagnostic while static for five seconds and during at least ten seconds of continuous drag, scroll or animation, together with the Viewer encoded/presented FPS. Formal performance conclusions still require the existing 600-second/30-minute runners.

## Mini observation

The user installed the stage-rate build and reported:

```text
static:
  capture / encode / Rust admission = 23.3 / 23.4 / 22.6 FPS
  capture lifetime average = 20.9 FPS
  target / applied = 15 / 15, high-motion, moderate pressure

continuous drag:
  capture / encode / Rust admission = 20.8 / 20.9 / 20.9 FPS
  capture lifetime average = 20.9 FPS
  target / applied = 15 / 15, high-motion, moderate pressure

Viewer encoded / presented = 20.4 / 20.4 FPS
```

There is no material throughput discontinuity across capture, VideoToolbox, Rust queue admission or Viewer presentation in this observation. The current limiting authority is the moderate pressure ceiling. The trailing five-second rate may still contain frames from before a cadence transition, so a recent rate above the current applied value does not by itself prove sustained ScreenCaptureKit pacing failure. H2.2.10 must identify the current pressure cause before any threshold or policy change.
