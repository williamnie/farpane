# H2.2.7 local live cadence diagnostic

Date: 2026-08-08

## Outcome

The local Host card now makes the existing adaptive-cadence authority visible during a real session. This is a diagnostic boundary for the reported 8.3–12 FPS observation, not a performance-policy change or a claim that the observation is normal.

## Data path

- `HostMediaPipeline.telemetry.snapshot()` remains the in-process authority.
- The existing 0.5-second Host snapshot poll reads a small locked aggregate snapshot on the main thread.
- `HostHomeSnapshot` carries only a preformatted local diagnostic string.
- `HomeView` hides the row when no media pipeline is active.
- The row shows capture lifetime average FPS, target/applied FPS, content state, pressure level, and an in-flight reconfiguration marker.

Interpretation is deliberately bounded:

- target/applied `12/12` with `lowMotion` means adaptive cadence intentionally applied the low-motion tier;
- target/applied `30/30` while Viewer encoded/presented remains near 8 FPS requires downstream encode/send/decode/render investigation;
- target and applied disagreeing, or a persistent in-flight marker, points to capture configuration lifecycle;
- lifetime average capture FPS is not an instantaneous FPS measurement.

No frame content, dirty-rect coordinate, peer/server metadata, address, credential, key, or raw error is added. There is no Host ABI, wire, Hermes, persistence schema, dependency, or cadence-policy change.

## Verification

```text
RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 113 passed, 0 failed; built Host core loaded

swift build -c release
result: passed
```

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808103630/FarPane-arm64-20260808103630.zip
SHA-256: b0f16f8cd21c17f5e0b5b1d9eb71320a6fbb0fe62c3db7d9603d9f0c9d97ef3b
```

The executable and bundled core are arm64. Stable Apple Development signing, strict deep verification, ZIP integrity, extracted-app signature/build-number verification, and a credential-like filename scan passed.

## Remaining evidence

The new build must still be installed on the Mini. During a fresh route, compare the local Host row with the Viewer HUD first while static, then during continuous drag/scroll or animation. Formal performance conclusions still require the existing H2 scenario runner and persisted telemetry rather than a visual spot check.
