# H6.2e event-first clipboard listener and bounded macOS fallback backoff

## Outcome

The native Host clipboard service remains event-first: it blocks on the
listener channel, reads clipboard content only for `CallbackResult::Next`, and
uses its existing 333 ms receive timeout only to re-check service lifetime.
The timeout branch does not read or poll the clipboard.

The pinned macOS clipboard backend observes `NSPasteboard.changeCount`, so the
Host-feature integration now supplies a bounded fallback schedule instead of
the backend's fixed interval:

```text
125 ms -> 250 ms -> 500 ms -> 1,000 ms -> 2,000 ms -> 4,000 ms (capped)
```

Every actual clipboard-change callback resets the next wait to 125 ms before
broadcasting the event to the service. This keeps the active-change response
short while bounding idle wakeups. Apple documents `changeCount` as the
pasteboard ownership-change authority:
<https://developer.apple.com/documentation/appkit/nspasteboard/changecount>.

## Scope and compatibility

The dynamic fallback is compiled only for `macOS + rdn-native-host`. Windows
and X11 keep their native event backends, and builds without the Host feature
retain the pinned upstream `clipboard-master` behavior. Android and the
Viewer-only product path are unchanged.

The H6.2a `enable-clipboard=N` startup/readback policy remains authoritative,
so this step does not enable clipboard transport. It adds no C ABI, XPC schema,
UI, dependency or protocol change and performs no real pasteboard read/write.

## Verification

- Pure backoff-state and real Handler-callback regression tests: pass.
- Full pinned Rust suite with `rdn-native-core,rdn-native-host`: 157/157.
- Pinned Rust library check with `rdn-native-core` and no Host feature: pass.
- Fresh arm64 Release Rust Core build: pass.
- Full Swift suite loading the fresh Core: 898/898.
- Full ScriptTests suite: 119/119.
- Fresh arm64 Release Swift build: pass.
- H6.2e audit: `event-first-bounded-macos-fallback`, 12/12 evidence and
  12/12 source anchors.
- H6.2a through H6.2d2 compatibility audits: pass.
- Tracked RustDesk patch reverse-check, touched Rust formatting, nested/root
  whitespace checks: pass.

The upstream workspace-wide formatter still reports unrelated pinned-source
format drift and an absent inline module; the touched `src/clipboard.rs`
passes `rustfmt --check` directly.

## Remaining H6.2 work

- define and enforce temporary clipboard object and promise-provider cleanup
  at unsubscribe, session teardown and process termination;
- add explicit product enablement and Viewer clipboard APIs only after that
  lifecycle boundary exists;
- keep rich clipboard payloads closed until their independent bounded transfer
  and cleanup contracts are implemented;
- measure enabled two-machine event latency and idle CPU on physical Macs.

## Operational boundary

No App or Agent was installed, launched, registered or restarted. No real
configuration, pasteboard, credential, key, Hermes service or network state was
read or changed. No package was emitted, pushed or deployed.
