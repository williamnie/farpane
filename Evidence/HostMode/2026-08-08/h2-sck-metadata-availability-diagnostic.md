# H2.2.15 ScreenCaptureKit metadata availability diagnostic

Date: 2026-08-08

## Outcome

FarPane now records the sanitized cumulative availability needed to explain the failed H2.2.14 Mini result. The diagnostic distinguishes ScreenCaptureKit frame-status delivery and dirty-rect attachment shape without changing capture cadence or inspecting content.

## Evidence boundary

Every screen callback is classified once as one of:

- `complete`, `idle`, `blank`, `suspended`, `started`, `stopped`;
- `missingOrInvalid` when no recognized numeric status exists;
- `unknown` for a future SDK status.

Only a `complete` callback is additionally classified as dirtyRects attachment `absent`, `unrecognized`, `recognizedEmpty` or `recognizedNonEmpty`. The callback total and both distributions are updated under the same telemetry lock. Therefore every snapshot preserves:

```text
sum(frame-status counts) == capture callback count
sum(dirtyRects counts) == complete frame count
```

No raw status value, attachment key/value, rectangle coordinate, pixel, display/peer/connection identifier, server setting, credential, path, payload or error text is retained. The existing frame handling and cadence observations use the same parsed attachment object but retain their prior fail-safe policy.

## Log and analyzer contract

The local HostMedia JSONL writer uses additive source schema v2 with:

```text
captureCallbackCount
captureFrameStatusCounts
captureCompleteDirtyRectsCounts
```

The repository analyzer accepts both source v1 and v2. V2 records fail closed on missing or unknown nested fields, non-integer/negative counts, count-conservation failure, mixed route schema, or decreasing cumulative values. The analysis result reports the source version and final cumulative distributions. All three existing Mini v1 logs still pass unchanged.

This step does not modify Host ABI, Rust wire, Hermes, route-stop evidence, cadence/pressure thresholds, dependencies, CI, database or root configuration.

## Verification

```text
swift test --filter 'Host(ScreenCapture|MediaTelemetry)Tests'
result: 19 passed, 0 failed

swift test --filter HostMediaTelemetryLiveLogTests
result: 2 passed, 0 failed

python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'
result: 20 passed, 0 failed

strict analyzer replay against all three existing Mini schema-v1 logs
result: 3 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 124 passed, 0 failed; built Host core loaded and lifecycle passed 3/3

swift build -c release --arch arm64
result: passed

RDN_HOST_GOLDEN_APP=".../FarPane.app" Scripts/preflight-host-mode-h1-golden.sh
result: H1_GOLDEN_PREFLIGHT_READY; patch reverse checks, stable signing,
latest executable/core UUID match, sanitized diagnostic and real
ScreenCaptureKit to hardware H.264 path passed
```

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808120005/FarPane-arm64-20260808120005.zip
SHA-256: afcf32a717fd84e72c8545b87061ffd87a691f3e7aad00c9302fd4e968366d2e
```

The executable and bundled core are arm64. Stable Apple Development signing, non-CDHash designated requirement, strict deep verification, ZIP extraction, build-number, architecture and executable-integrity verification passed.

## Real Mini validation

Build `20260808120005` produced 158 schema-v2 records over 162.30 seconds. It observed 3,754 capture callbacks: 3,745 complete and 9 idle. All 3,745 complete callbacks classified dirtyRects as `unrecognized`; none were absent, recognized-empty or recognized-nonempty. This establishes that the attachment exists in a runtime representation not covered by the current decoder.

The run is not a valid completion or performance acceptance: it has no final lifecycle record, and macOS generated a matching `EXC_BAD_ACCESS` crash report at the terminal timestamp. The independent H.265 frame-context ownership fault and fix are recorded in `h2-videotoolbox-frame-context-ownership.md`. A fixed build must repeat the run and disconnect normally before this evidence can close.
