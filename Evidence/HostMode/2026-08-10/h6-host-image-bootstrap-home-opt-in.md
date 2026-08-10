# H6.2k5 Host image bootstrap and Home opt-in

Date: 2026-08-10

## Outcome

Host image clipboard is now a product-level, explicit, directionally
independent opt-in. The background HostAgent and legacy foreground Host consume
the same six-direction small-text/rich-text/image policy and pass its image
directions to Host Control ABI v15. Core defaults and missing product
preferences remain false.

## Contract

- Bootstrap schema v4 adds `allowRemoteImageRead` and
  `allowRemoteImageWrite` beside the four existing clipboard directions.
- Schema v1 migrates all six directions to disabled. Schema v2 preserves small
  text while disabling rich text and images. Schema v3 preserves small/rich
  values while disabling both image directions.
- The decoder requires exact keys and real JSON Booleans; partial policies,
  numeric Boolean lookalikes, extra fields, and future schema versions fail
  closed.
- All six directions participate in canonical projection equality and
  `configRevision` advancement. Publishing a semantically identical v3 policy
  still advances once to persist schema v4 with image disabled.
- Home exposes separate image read/write switches and labels the 128 MiB
  RGBA/PNG and 4 MiB SVG caps. They reuse the existing gate that only permits
  changes while Host is off, control state is coherent, and no Viewer
  connection is starting.
- Missing UserDefaults values are false. A preference mutation republishes the
  immutable bootstrap; Host enable remains unavailable when publication is not
  coherent.
- The existing Viewer image owner and Host bounded image data-plane become
  end-to-end capable only after the user explicitly enables the matching Host
  direction. SVG is still untrusted transport data, not sanitized render
  input, and file promises remain unsupported.

## Verification

- Focused bootstrap migration, revision, integration, preparation, and Home
  product-chain tests: 19/19 passed.
- Full Swift suite with the ABI-v8/Host-ABI-v15 arm64 Core loaded: 924/924
  passed.
- Full ScriptTests suite: 135/135 passed.
- H6.2k5 machine audit status: `host-image-bootstrap-home-opt-in-ready`,
  14/14 evidence and 15/15 source anchors.
- Fresh arm64 Release Swift build: passed.
- Python compile and `git diff --check`: passed.
- No Rust source, native ABI, pinned patch, or dependency changed in this step;
  the fresh ABI-v8/Host-ABI-v15 arm64 Core from H6.2k4 is reused for Swift
  integration verification rather than rebuilding unchanged Rust code.

## Operational boundary

No App or Agent was installed, launched, registered, or restarted. No real
pasteboard was read or written. No credential, key, Hermes service, CI,
database, dependency, network service, deployment, or push state was changed;
no credential or key value was output.

## Remaining boundary

Installed two-Mac RGBA/PNG/SVG transfer, ownership, teardown, latency, and idle
CPU acceptance remains required. File-promise clipboard and H6.3 file transfer
remain separate future work.

Next boundary: `host-image-clipboard-installed-two-mac-acceptance`. If the
second Mac is unavailable, the next safe automatic implementation boundary is
the H6.3 file-transfer security/default-off contract.
