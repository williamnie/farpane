# H2.2.11 automatic local live telemetry log

Date: 2026-08-08

## Outcome

The Host app now records continuous, sanitized media telemetry locally so the operator does not need to stop an active drag or scroll gesture to copy the on-screen diagnostic. Each media route gets a distinct JSONL file under `~/Library/Logs/FarPane/HostMedia/`.

## Triggering observation

The Mini's H2.2.9 reading aligned capture, encode, Rust admission and Viewer presentation at roughly 20 FPS, with target/applied `15/15`, high-motion content and moderate pressure. Copying the UI text ends the active gesture, so a five-second point reading cannot preserve the transition and recovery timeline needed to identify the pressure trigger.

## Boundary

The writer records route start, route stop and route start failure even for a short session. Periodic samples are limited to one line per second and 3,600 samples per route; reaching that bound still permits the final lifecycle record. A UUID-backed per-route filename prevents overwriting earlier sessions, and logging failure disables only the current writer instead of interrupting capture or transport.

Schema `farpane-host-media-live` version 1 has an explicit performance-only allowlist:

- five-second capture, encode and Rust-admission FPS plus lifetime capture average;
- requested, target and applied FPS, content state, dirty-metadata trust and latest aggregate dirty ratio;
- applied/current pressure and deterministic pressure causes;
- aggregate encoder, send outcome, Rust queue and network pressure inputs;
- aggregate process CPU, memory, thermal and power fields.

It excludes local/peer/connection/display IDs, server configuration, public keys, passwords, credentials, filesystem output paths, frame contents, dirty-rect coordinates, encoded payloads and raw errors. It does not alter the explicit route-stop evidence schema.

No Host ABI, wire protocol, Hermes service, pressure/cadence threshold, queue policy, root dependency, CI or database change.

## Verification

```text
swift test --filter HostMediaTelemetryLiveLogTests
result: 2 passed, 0 failed

RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test
result: 118 passed, 0 failed; built Host core loaded and Host lifecycle passed 3/3

swift build -c release
result: passed
```

The focused tests verify lifecycle persistence, one-second periodic throttling, the per-route periodic bound with a final lifecycle record, sequence continuity, pressure-source values, field allowlisting, invalid bound and unsafe extension/relative-path rejection, and no-overwrite behavior.

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808110957/FarPane-arm64-20260808110957.zip
SHA-256: fb29d80aae4340783fa125723475b892fc207b03488d4b6f47a248821314b59f
```

The executable and bundled core are arm64. Stable Apple Development signing, strict deep verification, ZIP integrity, extracted-app signature/build-number/architecture verification and credential-like filename scanning passed.

## Remaining evidence

Install the new arm64 build on the Mini. Keep the connection static for at least 10 seconds, then continuously drag or scroll for at least 10 seconds, then disconnect normally. Retrieve the newest JSONL only after the gesture ends; the continuous timeline can then be analyzed without the copy action changing the measured state.
