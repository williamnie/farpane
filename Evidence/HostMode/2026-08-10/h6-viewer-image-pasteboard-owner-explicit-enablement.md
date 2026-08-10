# H6.2k4 Viewer image pasteboard owner and explicit enablement

## Outcome

FarPane's three real Viewer connection paths now explicitly enable ABI-v8
image receive and send: device connection, automatic recovery, and environment
live mode. The Core defaults remain false, so callers outside those product
paths do not gain image clipboard access implicitly.

The existing single AppKit pasteboard owner now owns small text, rich text, and
image formats. It remains bound to one authenticated/streaming clipboard
session epoch, reads only after `changeCount` changes, suppresses its own
writes, backs polling off from 125 ms to 4 seconds, and stops before Core
disconnect.

## Image format boundary

- Local `public.svg-image` bytes are preferred and validated as bounded
  canonical SVG.
- Local PNG is passed only after the shared canonical PNG policy succeeds.
- Local TIFF is limited to 128 MiB, preflighted through ImageIO without image
  caching, restricted to exactly one image and the shared dimension/pixel
  bounds, then converted to canonical PNG.
- Remote RGBA is validated and converted to a bounded PNG pasteboard
  representation; remote PNG and SVG retain their standard pasteboard types.
- If an image type is present but invalid, the item fails closed instead of
  falling back to rich or plain text.
- SVG remains untrusted transport data and is not claimed to be sanitized for
  rendering.

The remote callback reuses the existing Core generation, connection attempt,
and clipboard session epoch gates, so a stale Core or recovery-gap callback
cannot write into the current pasteboard.

## Verification

- RED contract test failed because `ViewerClipboardImagePolicy` and image owner
  composition were absent.
- Focused image policy and Viewer composition tests: 4/4 passed.
- Full Swift suite using the fresh ABI-v8/Host-ABI-v15 Core from H6.2k3:
  922/922 passed.
- Full ScriptTests suite: 134/134 passed.
- Fresh arm64 Release Swift build: passed.
- Isolated named-pasteboard AppKit smoke: TIFF preflight/read, TIFF-to-PNG
  conversion, and PNG write/read passed without touching `.general`.
- H6.2k4 machine audit status:
  `viewer-image-pasteboard-owner-explicitly-enabled`, 14/14 evidence and 13/13
  source anchors.

No Rust source, native ABI, pinned patch, or dependency changed in this step,
so the previous fresh native Core was loaded for the complete Swift regression
rather than rebuilding unchanged Rust code.

## Remaining boundary

Host image directions still default to false and are not present in Host Agent
bootstrap, Home preferences, or legacy Host product configuration. The next
bounded step is `host-image-bootstrap-home-opt-in-contract`, followed by
installed two-Mac image ownership, teardown, latency, and idle-CPU acceptance.

## Operational boundary

No App or Agent was installed, launched, registered, or restarted. The smoke
used a process-unique named pasteboard and did not read or write the user's
general pasteboard. No credential, key, Hermes service, CI, database, or
network state was read or changed. No package was emitted, pushed, or deployed.
