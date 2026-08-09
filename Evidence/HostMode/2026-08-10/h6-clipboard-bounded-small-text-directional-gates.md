# H6.2c bounded small-text directional clipboard gates

## Outcome

The native Host connection now has separate real data-plane gates for remote
clipboard read and remote clipboard write while the product capability remains
default off.

Remote read is checked twice: before subscribing the connection to the local
clipboard service and again for every clipboard message delivered to that
connection. Remote write is checked after authenticated remote-scope routing
but before `update_clipboard` can reach the macOS pasteboard.

Both directions accept only one bounded plain-text entry:

```text
format               ClipboardFormat::Text only
entry count          exactly 1
UTF-8 bytes          1...65536
decoded zstd bytes   1...65536
special name         empty
width / height       0 / 0
```

HTML, RTF, images, special formats, invalid UTF-8, empty content, multiple
entries, oversized wire content and oversized decompressed content fail
closed. Compressed input is first decoded through a new bounded zstd helper,
so an accepted message cannot subsequently expand beyond the same limit in the
legacy clipboard adapter.

## Direction authority

`NativeClipboardPolicy.remote_read` controls local clipboard subscription and
outgoing message delivery. `NativeClipboardPolicy.remote_write` independently
controls incoming message admission. Unit fixtures cover read-only and
write-only policies in both directions.

The broker binds its clipboard policy from the explicit Host option and resets
it to disabled when the Host unbinds. Connections compiled without native Host
support, or running without a native Host binding, preserve pinned upstream
behavior.

## Closed runtime boundary

The H6.2a startup authority still persists and verifies:

```text
enable-clipboard=N
```

Consequently this step does not enable clipboard capability, advertise it in a
real session, subscribe to the pasteboard, apply a remote pasteboard write, add
a UI switch, or expose a Viewer clipboard API. No Host ABI, snapshot schema,
XPC schema or network protocol changed.

## Remaining H6.2 work

- define independently scoped read/write revoke commands and snapshot
  convergence;
- replace the fixed 333 ms fallback cadence with event-first observation and
  bounded dynamic backoff;
- own temporary-object and promise-provider cleanup on connection teardown;
- add explicit product enablement and Viewer send/receive APIs only after the
  remaining lifecycle gates exist;
- keep files, images and other rich types closed until their separate transfer
  limits and cleanup contracts are implemented.

The next bounded implementation is
`independent-directional-revoke-contract`.

## Verification

- Full pinned Rust library suite with `rdn-native-core,rdn-native-host`:
  154/154.
- Focused hbb_common bounded-decompression tests: 2/2.
- Focused Rust directional/payload tests: 2/2.
- Fresh arm64 Release Core build completed and exported all required Viewer and
  Host symbols.
- Full Swift suite loading that fresh Core: 897/897.
- Full ScriptTests suite: 116/116.
- Clipboard data-plane audit: `bounded-small-text-directional-gates`, 10/10
  evidence and 9/9 source anchors.
- H6.2a and H6.2b compatibility audits: pass.
- Canonical/vendored Host bridge byte identity and both tracked reverse-patch
  checks: pass.

Existing upstream compiler warnings remain unchanged; no test failed.

## Operational boundary

No App/Core was installed or launched, no Host Agent was registered or
restarted, and no real configuration, pasteboard, credential, Hermes service
or network state was accessed. The Release Core was rebuilt only for local
link/load verification; no replacement App package was emitted in this step.
