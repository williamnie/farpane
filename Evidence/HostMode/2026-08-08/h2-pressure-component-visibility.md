# H2.2.10 pressure component visibility

Date: 2026-08-08

## Outcome

The local Host diagnostic now identifies which existing backpressure inputs currently cross policy thresholds and distinguishes them from the pressure level still applied by cadence hysteresis. This is diagnostic visibility for the Mini's severe/moderate observation, not a policy or threshold change.

## Authority

`HostCaptureBackpressure.assessment(maximumFramesPerSecond:)` is now the single authority for both current level and causes. The existing `level(...)` delegates to the assessment, so the control decision and diagnostic reasons cannot use separate threshold implementations.

Causes are deterministic and cover every current policy input:

- thermal state and low-power mode;
- encoder in-flight count and latest latency relative to negotiated frame budget;
- consecutive Rust-admission drops and the bounded recent drop-rate window;
- production Rust encoded-queue occupancy;
- current route network delay, RTT and response-delayed subscriber count.

The existing cadence pressure remains the applied, hysteresis-filtered level. The new observed level is a current raw assessment. If applied remains severe while observed has recovered, the UI explicitly reports hysteresis recovery rather than displaying an unexplained empty cause.

The UI formats only already-available aggregate values: counts, queue depth/capacity, milliseconds, percentage, thermal label and low-power boolean. It includes no frame/packet payload, dirty-rect coordinate, peer/server metadata, address, credential, key or raw error.

No Host ABI, wire protocol, serialized evidence schema, dependency, queue/cadence threshold or Hermes configuration changes.

## Verification

The cause test exercises all ten sources in one deterministic order and verifies severe precedence. Telemetry tests verify current network/RTT causes, current recovery to none, and preserve the existing cadence pressure tests.

```text
swift test --filter HostCaptureCadenceTests
result: 13 passed, 0 failed

swift test --filter HostMediaTelemetryTests
result: 13 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 116 passed, 0 failed; built Host core loaded and Host lifecycle passed 3/3

swift build -c release
result: passed
```

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808105902/FarPane-arm64-20260808105902.zip
SHA-256: 44e31d95a872e589f04d495138f6d19d71cce32672e6d39fb8d72f5e4c2bac46
```

The executable and bundled core are arm64. Stable Apple Development signing, strict deep verification, ZIP integrity, extracted-app signature/build-number/architecture verification and a credential-like filename scan all passed.

## Remaining evidence

Install the new arm64 build on the Mini and report the complete two-line Host diagnostic for five seconds static and at least ten seconds continuous motion. The cause text will determine whether the next step is a correctness fix, pressure-window tuning backed by evidence, or downstream investigation. Formal performance acceptance still requires the existing long-running scenarios.
