# H6.2k3 Host-Viewer image transfer wiring contract

## Outcome

The Host Control ABI is now version 15 and carries independent image read and
write policy flags. Both flags default to false. The native Host bridge admits
exactly one validated RGBA, PNG, or SVG clipboard entry only when the active
session direction and the matching image-format direction both allow it.
Rich-text policy cannot authorize an image payload.

Validated image input is rebuilt as one canonical uncompressed RustDesk
clipboard message before it reaches the pinned connection writer or pasteboard
helper. RGBA retains its validated dimensions; PNG and SVG use zero wire
dimensions. Special names and multi-image batches remain rejected.

The pinned connection patch already routes clipboard messages through the
generic outgoing and incoming native gates, so no second data-plane patch was
needed. The canonical and vendored Host bridges are byte-identical.

## Compatibility and product boundary

- Host Control ABI: 14 -> 15.
- Host Media ABI: unchanged at 1.
- Viewer ABI: unchanged at 8.
- Small text and rich text retain their independent policies.
- Image receive and send remain disabled in the Viewer product, Host App, and
  Host Agent.
- The single AppKit pasteboard owner does not yet read or write image types.
- SVG rendering sanitization is not claimed by this transport-only step.

## Verification

- Full pinned Rust suite with `rdn-native-core,rdn-native-host`, serialized:
  179/179 passed.
- Viewer-only Rust library check with `rdn-native-core`: passed.
- Fresh arm64 Release Rust Core build: passed; ABI-v15 dylib emitted.
- Full Swift suite loading that fresh Core: 921/921 passed.
- Full ScriptTests suite: 133/133 passed.
- Fresh arm64 Release Swift build: passed.
- H6.2k3 machine audit status:
  `host-viewer-image-transfer-wired-default-off`, 14/14 evidence and 12/12
  source anchors.
- Python compile check, Rust format check, canonical/vendor comparison, and
  repository whitespace check: passed.

## Intermediate verification notes

The first parallel full Rust run had one failure in the pre-existing current
cursor fixture. That exact test passed immediately in isolation, and the full
suite then passed 179/179 with one test thread. A Viewer-only check was first
invoked with `--no-default-features`, which removed existing audio features and
failed outside this change; the correct product-feature check passed.

The first complete ScriptTests run exposed five older audits whose current
Host ABI assertions still expected v14. Their historical semantics and schema
versions were left unchanged; only the current ABI marker and matching tests
were advanced to v15. The complete rerun passed 133/133.

## Remaining boundary

The next bounded step is
`viewer-image-pasteboard-owner-explicit-enablement-contract`: teach the single
Viewer pasteboard owner to handle bounded image representations with loop
suppression and lifecycle teardown, then explicitly opt the Viewer product in.
Host product opt-in and installed two-Mac image clipboard acceptance remain
separate later steps.

## Operational boundary

No App or Agent was installed, launched, registered, or restarted. No real
pasteboard, credential, key, Hermes service, CI, database, or network state was
read or changed. No package was emitted, pushed, or deployed.
