# H6.2a optional data capability default-off gate

## Outcome

Closed an unsafe gap between the documented product boundary and the pinned
upstream configuration semantics. RustDesk treats a missing `enable-*` option
as enabled. FarPane Host previously did not persist an explicit clipboard
value during startup, so “clipboard is disabled” was not proven by the actual
connection capability authority.

Every native Host start now writes these three independent optional
data-bearing upstream gates to `N` before the first identity/network runtime
access:

```text
enable-clipboard=N
enable-file-transfer=N
enable-audio=N
```

The existing private Host options readback now requires all three exact values
alongside the rendezvous, relay, key, keep-awake and stop-service projection.
Missing or stale optional-capability state fails Host startup before media or
network runtime creation.

## Runtime authority

The existing pinned connection code already derives clipboard subscription
and incoming clipboard admission from the same effective
`clipboard && !disable_clipboard` value. With the persisted local option set
to `N`, a native Host connection cannot advertise `readClipboard` or
`writeClipboard`, subscribe to the local clipboard service, or apply an
incoming clipboard message. File transfer and system audio use their own
local permission options and are likewise disabled.

This change does not read, write or observe the macOS pasteboard. It does not
add a clipboard ABI, protocol message, UI switch, transfer channel or payload
log.

## Remaining H6.2 boundary

Rich clipboard remains unimplemented and explicitly disabled. The audit
records the current gaps instead of treating upstream support as product
completion:

- the current Host capability is one clipboard Boolean and always couples
  `readClipboard` with `writeClipboard`;
- upstream rich clipboard accepts text, HTML, RTF, images and special types,
  including decompression, without FarPane-owned per-type/decompressed limits;
- the upstream listener uses a fixed 333 ms interval rather than a FarPane
  event-first/dynamic-backoff contract;
- temporary object/promise-provider cleanup is not owned by a FarPane
  connection-lifetime adapter;
- native Viewer clipboard send/receive APIs remain absent and disabled.

The next boundary is therefore a read/write policy contract and bounded small
text path. Images, files and other rich types must remain closed until their
separate limits and transfer lifecycle exist.

## Verification

- Full pinned Rust library tests with `rdn-native-host`: 151/151.
- Full Swift suite loading the freshly rebuilt arm64 Core: 897/897.
- Full script audit suite: 114/114.
- Optional capability audit: `optional-data-capabilities-default-off`, 10/10
  evidence and 9/9 source anchors.
- Focused audit test: 1/1.
- Canonical and vendored Host bridge byte identity: pass.
- Python compilation and diff checks: pass.
- Stable-identity signed arm64 Release App build `202608101410`: App and
  embedded Core are both exact arm64, strict deep signature verification
  passes, and the distributable ZIP SHA-256 is
  `000186d0a2098ee9ead71cd85883de884b2dd7797e91d283a56e1ff9a8759fa6`.

## Operational boundary

No App/Core was installed or launched, no Host service was registered or
restarted, and no real configuration, pasteboard, credential, Hermes service
or network state was accessed. The new uninstalled package is:

```text
Build/HostMode-arm64-202608101410/FarPane.app
Build/HostMode-arm64-202608101410/FarPane-arm64-202608101410.zip
```

The earlier `202608100549` package predates this gate and is superseded. The
new build must be installed before this default-off behavior reaches runtime.
