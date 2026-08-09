# H5.3w timestamped Host/Viewer lifecycle evidence writer

## Outcome

- Added `HostViewerConcurrencyEvidenceWriter`, a default-off process-scoped JSONL writer for the five §18/§20.3 V1 coexistence cases.
- Added one strict schema for App and HostAgent process lifecycle, normalized Host observations and normalized Viewer observations without changing product behavior or any Host/Media/XPC ABI.
- Added domain-separated SHA-256 helpers so raw process-start, build, Host instance and scenario identities never enter evidence records.
- Upgraded the rerunnable V1 audit from `checkpoint-required` to `writer-implemented` while keeping product composition, the five-result validator and live acceptance explicitly open.

## Process-scoped schema

App and HostAgent deliberately write separate files. Every schema-v1 record repeats the immutable observer scope:

- exact `application | hostAgent` role and PID;
- process-start identity SHA-256;
- build-identity SHA-256;
- scenario-correlation SHA-256;
- contiguous sequence, wall time and machine boot-monotonic time.

The first record must be `processStarted`; the final optional record is `processTerminating`. Events before start, duplicate start, any event after termination, non-increasing monotonic time, decreasing wall time and record 513 all fail closed.

Host observations carry only normalized states:

- `readyZeroInbound`;
- `inboundMediaActive`;
- `disconnected`;
- `recoveredReadyZeroInbound`;
- `recoveredInboundMediaActive`.

They bind a domain-separated Host scope digest, canonical nonzero Agent boot UUID, positive config revision, exact HostAgent PID/process-start digest/build digest and transition generation. Steady states require generation zero; disconnect/recovered states require a positive generation. A HostAgent writer additionally requires every Host observation to match its own immutable process/build identity.

Viewer observations carry only `starting`, `authenticatedStreaming`, `stopped`, `disconnected` or `recoveredStreaming`, plus a positive session epoch. Only the App role may write Viewer events. Steady lifecycle states require generation zero; disconnect/recovered states require a positive generation.

## Sanitization and file safety

The four digest domains are distinct:

- `farpane.v1-concurrency.process-start.v1`;
- `farpane.v1-concurrency.build.v1`;
- `farpane.v1-concurrency.host-scope.v1`;
- `farpane.v1-concurrency.scenario.v1`.

Raw identity is bounded to 1–512 printable UTF-8 bytes and retained only long enough to hash. Records contain no Host ID, peer ID, connection ID, credential, server configuration or media payload.

The output must be an absolute `.jsonl` path under an existing current-user-owned parent that is not group/world writable. Pure lexical path parsing rejects empty components, `.`, `..`, trailing slash and every parent symlink without relying on Foundation path canonicalization that changes `/private/var` aliases after file creation. Output is created without overwrite, changed to `0600`, rechecked as a current-user single-link regular file and held by one `FileHandle`; replacement of the visible path cannot redirect later appends. Every accepted line is synchronized before its sequence/state commits.

## Verification boundary

Focused tests cover exact record/event key sets, no raw identity leakage, four domain-separated digests, default-off configuration, relative/missing/unsafe/symlink/existing paths, `0600` single-link output, process/role/state/generation/timing failures, HostAgent self-identity, 64 concurrent callbacks, the 512-record cap and path replacement while the original fd remains open.

Fresh verification passed the focused Swift writer suite 7/7 plus focused audit 1/1, full ScriptTests 96/96, full Swift tests 863/863 with 4 expected built-core skips, arm64 Release build, Python compilation and `git diff --check`. The rerunnable audit reports `writer-implemented`, 19/19 evidence checks and 29/29 source anchors.

This step implements the writer/schema only. No App or HostAgent product owner constructs it yet, so no runtime artifact or live V1 pass is claimed. The next automatic boundary is an App process-lifetime evidence owner that derives authoritative identity, configures best-effort evidence, writes exact process start/termination and cannot affect App startup or shutdown. Host/Viewer lifecycle composition and the five-scenario validator remain later steps.
