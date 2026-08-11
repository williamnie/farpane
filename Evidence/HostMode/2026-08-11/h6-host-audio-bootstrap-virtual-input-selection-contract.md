# H6.1g Host audio bootstrap and virtual-input selection contract

Date: 2026-08-11

## Outcome

FarPane now carries an optional exact Host audio input name from a visible
Home selector through bootstrap schema v7 into both Host runtime owners. The
system-default microphone remains the default and audio remains opt-in.

## Contract evidence

- Bootstrap schema v7 adds `audio.inputDeviceName`; schema v6 enabled audio
  migrates to the default microphone.
- Disabled audio requires a null input name. Explicit names are limited to
  512 UTF-8 bytes and reject empty, padded, or control-character values.
- The product catalog enumerates CoreAudio devices with input channels and
  exposes only valid names that occur exactly once. It does not normalize or
  guess a device identity.
- Home exposes the system-default microphone, every unique exact input name,
  unavailable-selection state, and an explicit refresh action.
- Input selection uses the existing Host-off/no-Viewer/no-TCC-request policy
  gate. Missing, duplicate, invalid, or undiscoverable explicit inputs disable
  the effective policy and never fall back to the default microphone.
- Canonical bootstrap projection includes the selected input, so a change
  advances `configRevision` and reaches both the background HostAgent and the
  legacy foreground Host through Host ABI v19.

The H6.1g machine audit reports
`host-audio-bootstrap-and-virtual-input-selection-implemented` with 10/10
evidence checks and 8/8 source anchors.

## Verification

- Focused bootstrap configuration regressions: 13/13 passed.
- Focused Home routing/product source regressions: 14/14 passed.
- Full Swift suite: 1026/1026 passed; five environment-dependent tests were
  skipped by their existing gates.
- Full ScriptTests: 189/189 passed.
- H6.1g machine audit and the refreshed H6.1f ABI audit passed with no missing
  evidence or source anchors.
- Fresh isolated arm64 release build passed; the resulting
  `RustDeskNative` executable was verified as Mach-O arm64.
- `git diff --check` passed.

## Not claimed

- No virtual audio device was installed automatically.
- No TCC prompt, GUI launch, App installation, or live audio-device open was
  performed. The Mac mini's installed-device menu remains unverified.
- Dual-Mac audio, remote permission revocation, device disappearance while a
  session is live, latency, CPU, and interoperability remain unverified.
- RustDesk audio wire/payload ownership, Hermes, CI, root dependencies,
  databases, and secrets were not changed.

## Next boundary

`host-audio-product-development-completion-audit`: reconcile the H6.1
ownership matrix against H6.1a-g and record only installed/single-Mac and
dual-Mac acceptance as outstanding where appropriate.
