# H3.2b2 recoverable pending approval contract

Date: 2026-08-08

## Outcome

The native pending-request broker is now reachable through a versioned Host snapshot and exact approve/reject commands. App reconstruction can recover the same pending authority, and a local decision returns to the broker that owns deadline and single-final semantics.

## Contract

- Host Control ABI: v4.
- HostSnapshot: schema v3 with required `pendingApproval: object | null`.
- Host events: remain independently versioned at schema v1.
- Commands: exact `commandId`, `name`, `connectionId` fields for `approveConnection` and `rejectConnection`.
- Stable failures: not found `-21`, already finalized `-22`, expired `-23`.

The pending object carries only the canonical connection ID, bounded remote ID/name/platform marked `untrusted`, requested/expires wall-clock presentation times, fixed requested capabilities, transport classification, local-approval method and an empty risk array (schema v3 defines no risk codes yet). It carries no address, password, key, credential or raw authentication payload.

The broker's monotonic deadline remains authoritative. Snapshot copy first expires an overdue request and signals `Close`; approve before deadline signals `Authorize`, while reject and expiry signal `Close`. A duplicate or late decision cannot change the final state. Begin and every final transition emit `snapshotChanged` without coupling event schema to snapshot schema.

Swift decodes the pending object with an exact field set and bounded allowlists, exposes a typed decision method, and classifies the three stable failures. Unknown fields, future capability or risk names under schema v3, trusted remote metadata, malformed times and old snapshot versions fail closed.

## Scope exclusions

This step does not add the Swift incoming-request UI, alter RustDesk protobuf/wire authentication, implement the unsupported password-and-local-approval AND mapping, change Hermes, add a dependency, or modify CI/root configuration. H3.2 remains incomplete until the App presents and reconciles the request UI.

## Verification

Fresh verification completed against the rebuilt arm64 Host core:

- Rust native-approval tests: 2 passed, 0 failed (`native_approval`).
- Built-core Host contract/policy/lifecycle tests: 25 passed, 0 failed.
- Full Swift package tests: 126 passed, 0 failed.
- Script tests: 20 passed, 0 failed.
- `swift build -c release --arch arm64`: passed.
- `rustfmt --check`, canonical Rust source mirror, vendor `diff --check`, and both reverse patch checks: passed.
- `Scripts/preflight-host-mode-h1-golden.sh`: `H1_GOLDEN_PREFLIGHT_READY`; executable/core UUIDs match the current release/core builds, stable non-CDHash signing passed, and the real ScreenCaptureKit to hardware H.264 test executed without skip.

Local arm64 delivery artifact:

```text
Build/HostMode-arm64-20260808122922/FarPane-arm64-20260808122922.zip
SHA-256: 932ee65bc1e9ab082c8c82917ed9e8798568008e87c0df435d0ac2f824375dfc
```

ZIP integrity, extraction, build number `20260808122922`, arm64 executable/core, strict deep signing and extracted executable/core UUID verification passed. This artifact contains the ABI v4/schema v3 contract and the H.264/H.265 VideoToolbox frame-context crash fix, but does not yet contain the H3 incoming-approval UI.
