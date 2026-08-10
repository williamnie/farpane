# H6.2h Viewer pasteboard owner and explicit enablement contract

## Outcome

FarPane now has one Swift/AppKit owner for the native Viewer pasteboard. The
three real Viewer configuration paths explicitly enable ABI-v6 small-text
receive and send, while `CoreConnectionConfig` keeps both defaults false for
every other caller.

This is a Viewer-side product enablement only. Native Host startup still
persists and verifies `enable-clipboard=N`, so no end-to-end clipboard claim is
made until a separate Host opt-in contract is implemented.

## Owner and data boundary

- `ViewerPasteboardOwner` is the only Swift source importing AppKit and naming
  `NSPasteboard`.
- Rust remains unaware of the system pasteboard and exchanges only the H6.2g
  bounded semantic text callback/send API.
- Text must be non-empty, contain no NUL, and fit within 64 KiB as UTF-8.
- Clipboard text is never printed, audited, or persisted.
- The initial local `changeCount` is snapshotted when the authenticated session
  activates; pre-session clipboard content is not read or uploaded.
- The fallback observer reads text only after `changeCount` changes. Its delay
  grows through 125/250/500/1,000/2,000/4,000 ms and resets on activity.
- A successful remote write records the resulting `changeCount`, preventing
  the local observer from immediately echoing that write to the peer.

## Lifecycle and recovery

The App assigns a positive clipboard session epoch before creating Core. Core
callbacks carry both their immutable Core generation and clipboard epoch to
the main thread. Only the exact current tuple may write the pasteboard.

The owner activates after `.authenticated` (with `.streaming` as an idempotent
confirmation), suspends on every terminal state, and snapshots a new baseline
after automatic recovery. Clipboard changes made during the recovery gap are
therefore not sent when the replacement Core authenticates. Home and App
teardown stop the owner before Core disconnect; late callbacks fail closed.

## Compatibility

- Viewer C ABI remains v6.
- Host Control ABI remains v12.
- Host Media ABI remains v1.
- No Rust source, pinned upstream patch, XPC wire schema, shared ABI, root
  dependency, or Hermes behavior changed in this step.
- Rich text, images, files, file promises, and transfer channels remain off.

## Verification

- Focused Viewer polling and product composition tests: 9/9.
- Full Swift suite loading
  `Build/CoreBridge/arm64/liblibrustdesk.dylib`: 909/909.
- Full ScriptTests suite: 122/122.
- Fresh arm64 Release Swift build: pass.
- H6.2h machine audit:
  `viewer-pasteboard-owner-explicitly-enabled`, 13/13 evidence and 14/14 source
  anchors.
- Python compile and repository whitespace checks: pass.

## Intermediate failure resolved

The first composition test treated a CoreBridge documentation comment naming
`NSPasteboard` as a second pasteboard owner. The check now requires both the
AppKit import and pasteboard symbol, so it distinguishes an architectural
comment from executable ownership; the final focused and full suites pass.

## Remaining H6.2 work

- expose an explicit Host small-text clipboard opt-in while preserving the
  H6.2a default-off gate and independent read/write authority;
- run enabled two-Mac ownership, loop-suppression, disconnect/recovery,
  latency, and idle-CPU acceptance;
- keep rich payload and file-promise transfer behind their own future gates.

## Operational boundary

No App or Agent was installed, launched, registered, restarted, or deployed.
No real pasteboard, credential, key, Hermes service, CI, database, or network
state was read or changed. No package was emitted or pushed.
