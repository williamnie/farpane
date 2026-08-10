# H6.2g Viewer small-text clipboard API contract

## Outcome

The native Viewer C ABI is now version 6 and exposes one bounded semantic text
callback plus one dedicated text-send call. `CoreConnectionConfig` owns
independent receive and send policy flags; both default to false, so the current
FarPane product path remains unchanged until a later explicit enablement step.

Inbound data must be exactly one non-empty `ClipboardFormat::Text` entry with
no special name or image dimensions. Both compressed input and its decompressed
form are bounded to 64 KiB before UTF-8 decoding; invalid UTF-8, NUL, rich,
empty, multi-item, and oversized payloads fail closed. Outbound data uses the
same text validation and produces one canonical uncompressed RustDesk
clipboard message.

Receive delivery requires an active authenticated connection, local receive
policy, the remote clipboard permission, and an installed callback. Sending
requires the corresponding active/authenticated/local-send/remote-permission
tuple. The pinned RustDesk wire has one clipboard negotiation bit, but the
native bridge keeps the two local directions independently enforced.

## Pasteboard and lifecycle boundary

With `rdn-native-core`, Rust does not start the upstream clipboard listener,
does not perform initial clipboard sync, and never calls the system clipboard
update path. Callback-scoped Rust bytes are copied synchronously into Swift.
Swift then uses a lifecycle gate so disconnect disables clipboard delivery
before the Core disconnect call; callback work already queued for later is
dropped.

No `NSPasteboard` owner, polling, UI, or product enablement is included in this
step. Rich clipboard and file promises do not cross the Viewer ABI.

## Compatibility

- Viewer ABI: 5 -> 6.
- Host Control ABI: unchanged at 12.
- Host Media ABI: unchanged at 1.
- The shim and both build scripts require
  `_rdn_client_send_clipboard_text`, preventing an older Core from being loaded
  or packaged silently.
- The tracked pinned-upstream patch includes the Viewer client configuration,
  native no-pasteboard routing, and the default native UI callback seam.
- A no-feature Rust library check proves the ordinary upstream clipboard route
  still compiles after the native-only cfg split.

## Verification

- Full pinned Rust suite with current product features
  `rdn-native-core,rdn-native-host`: 161/161.
- Pinned Rust library check without native features: pass.
- Fresh arm64 Release Rust Core build: pass; required Viewer, Host Control, and
  Host Media symbols present.
- Full Swift suite loading that fresh ABI-v6 Core: 900/900.
- Full ScriptTests suite: 121/121.
- Fresh arm64 Release Swift build: pass.
- H6.2g machine audit:
  `viewer-small-text-clipboard-api-default-off`, 16/16 evidence and 16/16
  source anchors.
- H6.2a through H6.2f compatibility audit tests: pass with their next boundary
  advanced to the Viewer pasteboard owner/explicit enablement contract.
- Canonical and vendored Viewer bridges are byte-identical. The tracked
  RustDesk patch reproduces the nested regular-file worktree exactly; reverse
  apply and root whitespace checks pass.

## Intermediate failures resolved

The first no-feature compile exposed a missing `ClipboardSide` import after
the native-only cfg split; the import is now scoped together with the ordinary
upstream `update_clipboard` path and the compatibility check passes. The first
fresh-Core Swift run also found two Host bridge assertions still pinned to
Viewer ABI v5; both now assert v6 and the final 900-test run passes.

## Remaining H6.2 work

- establish a Swift/AppKit pasteboard owner with loop suppression, bounded
  observation, and teardown semantics;
- explicitly enable receive/send policy in the product only through that
  owner, while preserving independent directions;
- keep rich payload and file-promise transfer disabled until their separate
  transfer gates are implemented;
- run enabled two-machine ownership, teardown, latency, and idle-CPU acceptance
  on physical Macs.

## Operational boundary

No App or Agent was installed, launched, registered, or restarted. No real
pasteboard, configuration, credential, key, Hermes service, CI, database, or
network state was read or changed. No package was emitted, pushed, or deployed.
