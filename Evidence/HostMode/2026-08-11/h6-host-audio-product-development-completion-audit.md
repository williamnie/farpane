# H6.1 Host audio product development completion audit

Date: 2026-08-11

## Outcome

H6.1 audio product development is complete under the repository's current
single-Mac development-completion definition. Installed and two-Mac audio
acceptance remain explicitly unverified and do not masquerade as passing
evidence.

## Completion matrix

- Host audio is an independent immutable policy and remains default-off.
  Approval, subscription, and active-session revoke consume the same policy.
- Only the foreground FarPane App may request microphone TCC. The background
  HostAgent re-observes authorization without prompting, and permission loss
  disables only audio.
- Bootstrap schema v7 carries the exact optional input name. Host Home opt-in
  and policy mutation remain gated by Host-off/no-Viewer/no-TCC-request state.
- Viewer receive audio is an ephemeral connection opt-in. Local opt-in and
  authoritative remote permission jointly gate Rust playback; denial,
  revocation, replacement, and teardown reset playback state.
- The visible Host selector enumerates unique CoreAudio input names. Invalid,
  duplicate, missing, or drifting explicit selections fail closed and never
  fall back to the default microphone.
- The default route remains the native microphone. Third-party virtual input
  is user-selected only; FarPane does not install or silently select it.
- Capture, Opus encode/decode, `AudioFormat`/`AudioFrame`, buffer/resample, and
  native playback stay inside the pinned RustDesk data plane.

The refreshed ownership audit reports 16/16 evidence checks, 23/23 source
anchors, and no development gaps. The completion audit composes seven staged
audits and reports `product-development-complete` with 12/12 evidence checks,
16/16 source anchors, and no remaining development gaps.

## Verification

- All seven staged H6.1 machine audits passed with no missing evidence.
- Focused ownership and completion ScriptTests passed.
- Full ScriptTests: 190/190 passed.
- Full Swift suite: 1026/1026 passed; five environment-dependent tests were
  skipped by their existing gates.
- Fresh isolated arm64 release build passed and produced a Mach-O arm64
  `RustDeskNative` executable.
- Canonical RustDesk source verification and `git diff --check` passed.

## Not claimed

- The current build was not installed or launched, no TCC prompt was triggered,
  and no real audio input device was opened during this audit.
- Mac mini installed-build input enumeration and TCC remain unverified.
- Default-microphone and virtual-input capture/playback, remote denial and
  revocation, live device disappearance, dual-Mac latency/CPU, and
  interoperability remain unverified.
- Hermes, RustDesk audio wire, CI, root dependencies, databases, and secrets
  were not changed. No push or deployment was performed.

## Next boundary

`host-mode-development-completion-audit`: reconcile every H0-H6 development
requirement and staged completion audit against the current repository before
deciding whether any code work remains.
