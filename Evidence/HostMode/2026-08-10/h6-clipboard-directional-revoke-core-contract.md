# H6.2d1 independent directional clipboard revoke core contract

## Outcome

The native Host Core can now revoke remote clipboard read and remote clipboard
write independently for the exact active connection. The direct Swift
`HostControlClient` exposes the same two typed operations and waits for the
corresponding authoritative capability to disappear from the next Rust
snapshot.

This is deliberately a Host Core boundary. The existing background XPC command
schema and Home controls still expose only the legacy bidirectional clipboard
revoke; H6.2d2 must extend those surfaces separately.

## Runtime authority

Every inbound native Host connection created under an active Host binding owns
one shared `NativeClipboardPermissionState`:

```text
maximum = Host read/write policy intersected with upstream enable-clipboard
active  = atomic subset of maximum, initialized to maximum
```

The maximum never changes during the connection and an enable operation cannot
exceed it. The active value is shared by the connection and all its clipboard
service subscribers.

- `clipboard-read` changes only remote read, then re-evaluates the local
  clipboard service subscription.
- `clipboard-write` changes only remote write before the next incoming
  clipboard payload can reach `update_clipboard`.
- legacy `clipboard` changes both directions and remains the only form sent as
  RustDesk's single Clipboard permission wire bit.

The initial session snapshot and pending approval use maximum policy. The
active session snapshot and both real data paths use active policy. A Host
unbind makes clipboard delivery fail closed while non-clipboard service
messages remain unaffected.

## Command and compatibility contract

The exact-session broker accepts:

```text
disableClipboardReadForActiveSession
disableClipboardWriteForActiveSession
disableClipboardForActiveSession       legacy both-directions alias
```

Unknown, foreign, stale and unavailable sessions retain the existing
fail-closed error mapping. A direction already absent is idempotent and emits
no connection command. The command result only proves queued acceptance;
completion remains the authoritative snapshot losing the requested direction.

No Host C ABI, Host snapshot schema, XPC schema, network protocol or Hermes
service changed. Clipboard remains default off through the existing persisted
`enable-clipboard=N` authority.

## Verification

- Full pinned Rust library suite with `rdn-native-core,rdn-native-host`:
  155/155.
- Rust build without native Host features: pass.
- Focused hbb_common bounded-decompression tests: 2/2.
- Fresh arm64 Release Core build: pass; output at
  `Build/CoreBridge/arm64/liblibrustdesk.dylib`.
- Full Swift suite loading that fresh Core: 897/897.
- Full ScriptTests suite: 117/117.
- Directional revoke audit:
  `independent-directional-revoke-core-contract`, 11/11 evidence and 12/12
  source anchors.
- H6.2a/H6.2b/H6.2c compatibility audits: pass.
- Canonical/vendored Host bridge byte identity: pass.
- Tracked RustDesk patch forward/reverse checks and hbb_common reverse check:
  pass.
- Repository diff whitespace check: pass.

The build still reports the pinned upstream compiler warnings already present
before this step; no verification command failed.

## Remaining H6.2 work

- H6.2d2: add independently typed XPC commands and Home presentation/actions,
  preserving the legacy bidirectional command for compatibility;
- replace fixed 333 ms polling with event-first observation and bounded dynamic
  backoff;
- own temporary object and promise-provider cleanup at teardown;
- add explicit product enablement and Viewer clipboard APIs only after those
  lifecycle boundaries exist;
- keep rich payloads closed until their independent transfer and cleanup
  contracts are implemented.

## Operational boundary

No App or Agent was installed, launched, registered or restarted. No real
configuration, pasteboard, credential, key, Hermes service or network state was
read or changed. No package was emitted, pushed or deployed.
