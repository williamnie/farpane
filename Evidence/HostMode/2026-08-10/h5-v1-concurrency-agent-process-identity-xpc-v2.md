# H5.3af HostAgent process-identity XPC v2

## Outcome

The frozen H5.3ae process-identity contract is now implemented in the product XPC path. Handshake schema and wire version are both 2; version 1 no longer negotiates. The accepted Agent identity now consists of build ID, Host instance ID, Agent boot ID, exact Agent PID and the domain-separated kernel process-start SHA-256.

App Host lifecycle evidence remains deliberately unconnected. This step makes the required identity authoritative and available; the next step must compose it with validated Host projection/configuration state rather than claiming the broader lifecycle matrix here.

## Agent authority

`HostAgentXPCProcessIdentityAuthority.makeProduct` now captures `getpid()` and reads `PROC_PIDTBSDINFO` for that same PID before any Host binding or listener admission. It requires the returned kernel record to identify the requested PID, positive start seconds and microseconds below one million. The raw tuple is hashed in memory with `farpane.v1-concurrency.process-start.v1`, NUL separation and SHA-256; only the lowercase 64-character digest is retained in the immutable Agent process identity.

The process identity is captured once by the XPC authority. `HostAgentProcessRuntime` retrieves that immutable value and passes the same value to `HostAgentXPCCommandProcessOwner`; runtime and command composition do not call `getpid()` or `PROC_PIDTBSDINFO` independently. Binding a Host instance produces one five-field identity, while a conflicting Host binding or invalidation remains terminal.

## Strict wire and App binding

The handshake request and response use exact JSON key sets under schema 2. Response PID must be greater than one and process-start identity must be exactly lowercase SHA-256. Reconnect-known Host/boot/PID/start fields are all present or all absent; partial tuples fail closed. Schema 1, wire offers without version 2, Boolean/fractional/overflow PID values, uppercase or malformed digests, missing keys and extra keys are rejected.

The App constructs `HostAgentXPCSnapshotClientPeerIdentity` only from a decoded compatible handshake response. That peer identity includes all five fields. The same typed identity is retained by client snapshot/event/command states and by the per-connection Agent session handler, so subsequent traffic stays bound to the accepted handshake without duplicating process identity in the snapshot payload. On reconnect, equality compares all five fields; a PID/start-only replacement triggers the existing identity replacement reset before projection delivery.

The raw process-start tuple never crosses XPC and the snapshot payload still contains no process identity authority. App-side process discovery, PID-only identity and Agent boot UUID substitution remain absent.

## Verification boundary

The rerunnable audit is:

```sh
python3 Scripts/audit-host-agent-xpc-process-identity-contract.py
```

It must emit `status=wire-identity-v2-implemented`, no missing evidence or anchors, and `nextImplementationBoundary=application-host-lifecycle-observation-composition`.

Fresh verification passed with focused audit tests 2/2, full ScriptTests 97/97,
full Swift tests 882/882 with four expected built-core conditional skips, arm64
Release build, Python compilation and `git diff --check`. The focused contract
audit reports 13/13 evidence checks and 20/20 source anchors; the main H5 audit
reports 41/41 evidence checks and 94/94 source anchors.

## Remaining boundary

This step does not emit App-side Host lifecycle records, implement Viewer automatic recovery, aggregate the five ordered scenarios, install/deploy the build or claim a V1 concurrency pass. The next bounded step can consume the five-field peer identity together with coherent background projection and positive configuration revision to compose App Host lifecycle observation fail closed.
