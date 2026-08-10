# H6.2i1 Host clipboard explicit-policy ABI seam

## Outcome

Host Control ABI v13 can now carry independent, explicitly configured bounded
small-text clipboard read and write directions into one immutable Rust Host
lifetime. Both Swift defaults remain false, and the current foreground App and
background Agent callers do not opt in, so product Host clipboard behavior is
still default-off.

This step establishes the shared ABI seam only. It does not add a Home control,
change the background bootstrap schema, read or write a pasteboard, or claim
end-to-end clipboard availability.

## Authority and fail-closed behavior

- `RdnHostCreateOptions` carries `enable_clipboard_read` and
  `enable_clipboard_write`; Host ABI is synchronized at v13 in C and Rust.
- `HostServerConfiguration` exposes the same independent directions with both
  defaults false and copies them directly into the C create options.
- Rust copies the directions into `RdnHost.clipboard_policy` at create time and
  binds that exact policy into the native session/media broker.
- The pinned upstream Boolean adapter writes `enable-clipboard=Y` only if at
  least one independently enforced direction is enabled; otherwise it writes
  `N`.
- Startup storage verification derives the expected persisted value from the
  same immutable policy. Missing or stale readback fails before network/media
  startup.
- `enable-file-transfer` and `enable-audio` remain unconditionally pinned to
  `N`.
- Canonical and vendored Host bridge sources remain byte-identical.

## Product boundary

The existing App and Agent construct `HostServerConfiguration` without either
clipboard argument, so both use the false defaults. A later bounded step must
version and propagate these settings through background bootstrap, expose
explicit Home controls, and preserve default-off behavior for existing users.

## Verification

- Focused Rust policy and persisted-readback tests: pass.
- Full pinned Rust suite with `rdn-native-core,rdn-native-host`: 162/162.
- Fresh arm64 Release Core build and required-symbol checks: pass.
- Full Swift suite loading that Core, including Host ABI v13 lifecycle tests:
  910/910 with zero skips.
- Full ScriptTests suite: 123/123.
- Fresh arm64 Swift Release build: pass.
- Machine audit:
  `host-clipboard-explicit-policy-abi-ready-default-off`.
- Python compile, Rust formatting, canonical/vendor byte comparison, RustDesk
  and hbb_common reverse-patch checks, and repository whitespace checks: pass.

## Remaining H6.2 work

- propagate independent Host settings through a versioned background bootstrap
  contract and explicit Home controls;
- run installed two-Mac ownership, loop suppression, disconnect/recovery,
  latency, and idle-CPU acceptance;
- keep rich text, images, files, and file promises behind their own later
  payload/security gates.

## Operational boundary

No App or Agent was installed, launched, registered, restarted, or deployed.
No real pasteboard, credential, key, Hermes service, CI, database, or network
state was read or changed. No package was pushed.
