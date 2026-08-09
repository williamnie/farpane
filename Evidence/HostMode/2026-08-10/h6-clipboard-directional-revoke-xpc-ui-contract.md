# H6.2d2 directional clipboard revoke XPC and Home contract

## Outcome

The background Host Agent command path and the FarPane Home surface now keep
remote clipboard read and remote clipboard write revocation independent all the
way to the H6.2d1 Host Core authority.

Home presents two capability-scoped actions:

- `停止远端读取` removes only `readClipboard`;
- `停止远端写入` removes only `writeClipboard`.

A direction that is not present in the authoritative active-session snapshot
does not get a button or a command submission. Both the legacy in-process Host
owner and the background XPC owner use the same directional Home action model.

## Wire and compatibility contract

The strict Data-only command schema is now version 2 and freezes these
additional names:

```text
disableClipboardReadForActiveSession
disableClipboardWriteForActiveSession
```

Schema 1 and unknown future schemas fail closed. This is an intentional
semantic schema revision; the App and its bundled Host Agent are released as
one product. The Objective-C XPC selector, negotiated wire version, request
correlation, queued acceptance, command-ID dedupe and event/snapshot result
model did not change.

`disableClipboardForActiveSession` remains accepted and maps to the legacy
bidirectional Host Core operation so retained retry/result state and older
internal call sites remain representable. Current Home presentation does not
create this legacy action: it derives read and write actions independently from
the active capability set.

## Runtime and convergence contract

The Agent execution adapter maps the new names exactly to
`.disable(.clipboardRead)` and `.disable(.clipboardWrite)`. Approval commands
still target pending approval; all three clipboard command forms target only
the exact active session. Foreign, stale, limited-session and route-epoch
mismatches retain the existing fail-closed behavior.

After queued acceptance, Home remains pending until the authoritative snapshot
loses the requested capability. Retry preserves the original directional
action and command ID. Labels and accessibility descriptions distinguish
reading the local clipboard from writing to it.

The H6.2a `enable-clipboard=N` startup/readback policy remains authoritative.
This step does not enable clipboard transport, read or write a pasteboard, or
add rich clipboard data.

## Verification

- Focused wire, execution-adapter, Home policy/presentation-owner and product
  source projection tests: pass.
- Full Swift suite loading
  `Build/CoreBridge/arm64/liblibrustdesk.dylib`: 898/898.
- Full ScriptTests suite: 118/118.
- Fresh arm64 Release Swift build: pass.
- H6.2d2 audit: `directional-revoke-xpc-home-contract`, 12/12 evidence and
  12/12 source anchors.
- H6.2a/H6.2b/H6.2c/H6.2d1 compatibility audits: pass.
- Repository diff whitespace check: pass.

No Rust source or C ABI changed in this step, so the fresh Release Core from
H6.2d1 was reused for Swift linkage and runtime contract tests.

## Remaining H6.2 work

- replace fixed clipboard polling with event-first observation and bounded
  dynamic backoff;
- own temporary object and promise-provider cleanup at teardown;
- add explicit product enablement and Viewer clipboard APIs only after those
  lifecycle boundaries exist;
- keep rich payloads closed until their independent transfer and cleanup
  contracts are implemented;
- perform physical Home layout and two-machine directional revoke acceptance
  when a test package is produced later.

## Operational boundary

No App or Agent was installed, launched, registered or restarted. No real
configuration, pasteboard, credential, key, Hermes service or network state was
read or changed. No package was emitted, pushed or deployed.
