# H2.2.13 sustained near-full queue pressure

Date: 2026-08-08

## Outcome

Transient production encoded-queue occupancy at `capacity - 1` no longer immediately cuts capture from 30 to 15 FPS. Near-full occupancy must now persist across three consecutive one-second Rust samples. A full queue remains immediate severe pressure.

## Production evidence

The first automatic Mini log passed the H2.2.12 schema and lifecycle validator:

```text
duration: 98.399 seconds
records: 99 total, 97 periodic
codec: H.265, requested 30 FPS
capture / encode / Rust-admission median: 20.646 / 20.649 / 20.509 FPS
capture→encode / encode→Rust median absolute gap: 0.122 / 0.000 FPS
```

Queue samples:

```text
0/3: 59
1/3: 18
2/3: 19
3/3: 0
```

The 19 near-full samples were isolated or occurred in pairs, never three consecutively. Nevertheless, the old one-sample rule produced 40 applied-moderate samples, 10 in-flight `30/15` samples and repeated `30/30 → 15/15 → 30/30` cycles. `encodedQueue` accounted for 19 of 23 current moderate-cause samples. The send-drop window peaked at `3/32` and consecutive drops peaked at one, below their independent moderate boundaries.

This proves the approximately 20 FPS median came from policy oscillation rather than capture→encode→Rust stage loss. It does not prove that queue pressure can be ignored: a sustained near-full queue or actual full queue remains actionable.

The same log showed dirty metadata trusted in 0/97 periodic samples and high-motion in 97/97. That is recorded as a separate next investigation rather than mixed into this queue fix.

## Policy change

- queue full (`depth == capacity`) remains immediate severe;
- queue near-full (`depth == capacity - 1`) becomes moderate only after three consecutive validated one-second production samples;
- any lower depth, full sample or unavailable sample resets the near-full streak;
- existing send-drop, encoder, network, thermal/power thresholds and cadence recovery remain unchanged.

The streak is route-local, bounded and updated only when a validated Rust queue diagnostic arrives. Capture callbacks observe it but do not increment it, so repeated frames cannot turn one queue sample into sustained evidence.

No queue-capacity, Rust, Host ABI, wire, Hermes, dependency, CI or database change.

## Verification

```text
swift test --filter HostCaptureCadenceTests
result: 13 passed, 0 failed

swift test --filter HostMediaTelemetryTests
result: 13 passed, 0 failed

python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
result: 17 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 118 passed, 0 failed; built Host core loaded and Host lifecycle passed 3/3

swift build -c release
result: passed

RDN_HOST_GOLDEN_APP=".../FarPane.app" Scripts/preflight-host-mode-h1-golden.sh
result: H1_GOLDEN_PREFLIGHT_READY; patch reverse checks, stable signing, latest executable/core UUID match, sanitized diagnostic and real ScreenCaptureKit→hardware H.264 path passed
```

The tests distinguish one/two near-full samples from the third sustained sample, retain immediate full-queue severe pressure, and preserve deterministic cause ordering.

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808112209/FarPane-arm64-20260808112209.zip
SHA-256: 640efc1f73e6ace25c5a987d2a22aaa78bcec20672c38958061d8dcb42c0326d
```

The executable and bundled core are arm64. Stable Apple Development signing, non-CDHash designated requirement, strict deep verification, ZIP integrity and extracted-app signature/build-number/architecture verification passed.

## Remaining evidence

Install the new Mini build and repeat an uninterrupted static/continuous-motion/static route. The automatic log should show whether the `30↔15` queue-driven oscillation is gone. Encoder in-flight/latency transients and missing dirty metadata remain independently observable and must not be inferred away.
