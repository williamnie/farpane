# H2.2.8 bounded recent capture FPS diagnostic

Date: 2026-08-08

## Outcome

The local Host diagnostic now reports a bounded five-second capture rate beside the existing route-lifetime average. This closes the measurement ambiguity where an old lifetime average could hide the current result of sustained movement. It is diagnostic visibility, not a cadence-policy change or a performance-fix claim.

## Boundary

- `HostMediaTelemetry` keeps at most 1,202 monotonic capture timestamps, covering the configured upper bound of 240 FPS for five seconds plus endpoints.
- The recent rate counts only timestamps inside the trailing five-second window and includes trailing silence in its denominator.
- Fewer than two current samples, or no sample remaining in the window, yields zero rather than a stale rate.
- The route-lifetime `actualFPS` remains unchanged for formal persisted evidence compatibility.
- The Host card displays `capture recent 5s / lifetime average`, then the existing target/applied FPS, content tier, pressure and reconfiguration state.
- No frame pixels, dirty-rect coordinates, peer/server metadata, address, credential, key or error text enters the buffer.
- No Host ABI, wire protocol, serialized telemetry evidence schema, dependency, cadence policy or Hermes configuration changes.

## Interpretation

- recent capture near 30 with target/applied 30 while Viewer remains near 8 FPS: continue after the capture boundary through encode, send, decode and render;
- recent capture itself near 8 with target/applied 30: inspect ScreenCaptureKit delivery/configuration and dirty-rect classification;
- target/applied 12/12 with low-motion: the current core deliberately applied the low-motion tier;
- a persistent target/applied mismatch or reconfiguration marker: inspect capture configuration lifecycle.

## Verification

The deterministic unit test injects 31 monotonic timestamps over one second, requires both lifetime and recent rates to equal 30 FPS, advances the observation clock by six seconds without frames, then requires only the recent rate to decay to zero.

```text
swift test --filter HostMediaTelemetryTests
result: 12 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 114 passed, 0 failed; built Host core loaded and Host lifecycle passed 3/3

swift build -c release
result: passed
```

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808104337/FarPane-arm64-20260808104337.zip
SHA-256: 3d1e7503e3015a98567a7ea8987ebc0a493ff3e7bb7cf5dfa06bafe876d88e32
```

The executable and bundled core are arm64. Stable Apple Development signing, strict deep verification, ZIP integrity, extracted-app signature/build-number/architecture verification and a credential-like filename scan all passed.

## Remaining evidence

Install the new arm64 build on the Mini and compare the full Host diagnostic row with the Viewer HUD during five seconds static and at least ten seconds of continuous drag, scroll or animation. A visual spot check does not replace the existing 600-second/30-minute H2 performance runners.

## Mini observation

The user installed the H2.2.8 arm64 build and reported:

```text
static 5s: recent/lifetime capture 4.9/19.6 FPS
            target/applied 5/5, high-motion, severe pressure
continuous drag: recent/lifetime capture 23.4/19.6 FPS
                 target/applied 15/30, high-motion, moderate pressure, update in flight
Viewer: encoded 19.7 FPS, presented 19.7 FPS
```

This rules out the earlier low-motion hypothesis for the observed interval. The pressure controller's severe/moderate ceiling is authoritative, and Viewer presentation is not dropping materially below encoded rate. The aggregate pressure level alone cannot identify whether encode latency/in-flight, send drops, Rust queue occupancy, QoS delay/RTT, thermal state or low-power mode triggered it. H2.2.9 adds capture/encode/Rust-admission stage rates; a later bounded diagnostic must expose sanitized pressure components before changing policy thresholds.
