# H5.3ae HostAgent process-identity XPC contract

## Outcome

The versioned, fail-closed XPC contract required before App-side Host lifecycle evidence is now frozen as a rerunnable machine audit. This checkpoint deliberately does not modify the shared XPC schema or product behavior.

The current handshake remains strict schema/wire version 1 and carries only Agent build ID, Host instance ID and Agent boot ID. The App peer identity and background projection retain only those values, while the snapshot payload correctly does not claim process-identity authority. This is insufficient for the strict H5 lifecycle writer, which requires the exact HostAgent PID plus a domain-separated digest of the matching kernel process-start identity.

## Frozen version-2 boundary

The next implementation must make one incompatible, exact-key schema/wire version 2 upgrade. The accepted Agent identity is:

- `agentBuildID`;
- `hostInstanceID`;
- `agentBootID`;
- `agentProcessID`;
- `agentProcessStartIdentitySHA256`.

The HostAgent must capture `getpid()` once and read `PROC_PIDTBSDINFO` for that same PID before publishing its immutable XPC identity. PID must be greater than one, the kernel result must identify the requested PID with positive seconds and bounded microseconds, and only the existing domain-separated lowercase SHA-256 digest may cross XPC. The raw kernel start tuple must not enter XPC or evidence.

The App may accept these values only from a compatible version-2 handshake response. The complete five-field identity must remain pinned through snapshot and command traffic, be compared across reconnect sessions, and enter the background projection only after snapshot/identity coherence succeeds. Snapshot payloads must not duplicate or redefine process identity.

Schema/wire version 1 must not be accepted as a fallback for Host lifecycle evidence. App-side bundle process scans, PID-only identity, Agent boot UUID as process-start identity, caller-supplied identity, or a snapshot-derived identity are forbidden.

## Key evidence

- `HostAgentXPCWireHandshake` already rejects unknown schema values and extra/missing JSON keys, giving the next incompatible upgrade a fail-closed base.
- `HostAgentXPCProcessIdentityAuthority` already owns one process-lifetime identity, binds exactly one Host instance and terminally invalidates contradictions.
- `HostViewerConcurrencyEvidenceProcessOwner` already derives exact current PID plus `PROC_PIDTBSDINFO` process-start seconds/microseconds.
- `HostViewerConcurrencyEvidenceDigest` already defines the bounded, domain-separated process-start digest required by the lifecycle writer.
- App Host lifecycle composition remains unconnected, so the missing identity cannot currently produce guessed records.

## Verification

Run:

```sh
python3 Scripts/audit-host-agent-xpc-process-identity-contract.py
```

The audit must emit `status=contract-frozen`, no missing evidence or source anchors, schema/wire target version 2, the exact five identity fields, and `nextImplementationBoundary=host-agent-xpc-wire-identity-v2`.

Fresh H5.3ae verification completed on 2026-08-10:

- focused contract and main H5 audits: 2/2 passed;
- full ScriptTests: 97/97 passed;
- full Swift tests: 882/882 passed with four expected built-core conditional skips;
- arm64 Release build: passed;
- Python compilation and `git diff --check`: passed;
- focused contract audit: 9/9 evidence and 11/11 source anchors;
- main H5 audit: 41/41 evidence and 94/94 source anchors.

## Remaining boundary

This checkpoint is a contract freeze, not shared ABI implementation. The next bounded step may update the handshake identity authority, strict request/response codecs, client peer identity, reconnect continuity and focused Swift tests together as one versioned XPC contract. App Host observation composition remains a separate later step. Installed App/Agent and two-machine execution remain manual evidence, and no V1 concurrency matrix pass is claimed.
