# H6.2j6 Host rich-text bootstrap and Home opt-in

Date: 2026-08-10

## Outcome

Host rich-text clipboard is now a product-level, explicit, directionally
independent opt-in. The background HostAgent and legacy foreground Host consume
the same four-direction policy and pass it to Host Control ABI v14. Core and
product preferences remain off by default.

## Contract

- Bootstrap schema v3 adds `allowRemoteRichTextRead` and
  `allowRemoteRichTextWrite` beside the existing bounded small-text directions.
- Schema v1 migrates all four directions to disabled. Schema v2 preserves its
  small-text values but migrates both rich-text directions to disabled.
- The decoder requires exact keys and JSON Booleans; partial rich policy,
  numeric Boolean lookalikes, extra fields, and future schema versions fail
  closed.
- All four directions participate in canonical projection equality and
  `configRevision` advancement.
- Home exposes separate RTF/HTML read/write switches, labels the independent
  1 MiB representation cap, and only permits changes while Host is off, control
  state is coherent, and no Viewer connection is starting.
- Missing UserDefaults values are false. A preference mutation republishes the
  immutable bootstrap; Host enable remains unavailable when publication is not
  coherent.
- Image clipboard payloads and file promises remain disabled.

## Verification

- RED: the new schema-v3 regression initially failed to compile because
  `HostAgentClipboardPolicy` had only the two small-text arguments.
- `swift test --filter HostAgentBootstrap`: 34 tests passed.
- `swift test --filter HostAgentBackgroundHomeRoutingPolicyTests`: 10 tests
  passed.
- `RDN_CORE_LIBRARY=Build/CoreBridge/arm64/liblibrustdesk.dylib swift test`:
  921 tests passed, 0 failed, 0 skipped; the loaded dylib is arm64 and retains
  the already-verified Host ABI v14.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 130 tests
  passed.
- `swift build -c release`: succeeded.
- `audit-host-rich-text-bootstrap-home-opt-in-contract.py`:
  `host-rich-text-bootstrap-home-opt-in-ready`, 13/13 evidence and 15/15 source
  anchors.
- Python compile and `git diff --check`: passed.

## Boundary

No App/Agent was installed or started, no system pasteboard was read or written,
and no Hermes, CI, dependency, database, credential, deployment, or push state
was changed. Installed two-Mac RTF/HTML ownership, teardown, latency, and idle
CPU acceptance remains required.

Next boundary: `host-rich-text-clipboard-installed-two-mac-acceptance`. If the
second Mac is unavailable, the next safe automatic implementation boundary is
the bounded image clipboard payload contract.
