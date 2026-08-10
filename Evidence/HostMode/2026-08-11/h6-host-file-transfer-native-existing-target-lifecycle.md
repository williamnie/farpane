# H6.3e4c Native Host existing-target decision lifecycle

## Outcome

Authenticated dedicated file-transfer connections now detect an existing Native
Host destination through the pinned receive-root owner and wait for an explicit
sender decision. The implemented contract is deliberately no-replace and the
product capability remains disabled.

## Contract

- Existing targets are opened read-only through the admitted root descriptor
  with `O_NOFOLLOW`. Only current-euid, exact `0600`, single-link regular files
  are accepted; unsafe or ambiguous targets fail closed.
- The Host returns the destination's actual size, modification time and exact
  identical result in an upstream upload digest. No file block is accepted
  while that decision is pending.
- Explicit skip preserves the existing destination, removes a safe stale
  staging file descriptor-relatively, and accounts the skipped declared size
  so single-file and multi-file completion remain coherent.
- Offset, overwrite, `skip=false` and malformed decisions are rejected as
  unsupported replacement requests. The job is aborted and the existing file
  remains untouched.
- Final staging commits continue to use `RENAME_EXCL`; this boundary does not
  add delete-then-rename or replace semantics.

## Focused evidence

- A pending decision rejects an early data block, then skip completes while
  preserving the original bytes and cleaning an old partial.
- An identical destination reports exact metadata but an explicit replacement
  decision is rejected without changing it.
- A `0644` destination fails closed before data admission.
- A two-file batch commits the first new file, skips the second existing file,
  and finishes with exact logical total-size accounting.
- Canonical Host sources match the Vendor checkout. The new connection patch
  reverse-applies from the final layer, exposes the prior resume layer when
  removed, and reapplies cleanly; bootstrap is idempotent.

## Verification

- Focused existing-target Rust tests: 3/3 passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 207/207 passed.
- Viewer-only Release check with default upstream features and
  `rdn-native-core` (without `rdn-native-host`) passed.
- Fresh arm64 Release Core built successfully and was identified as a thin
  arm64 Mach-O dylib; Swift tests loading that exact Core: 924/924 passed.
- Full ScriptTests: 146/146 passed; all Host file-transfer audits passed.
- Swift Release build, owned Host-source `rustfmt --check`, Python compilation,
  patch replay/reverse checks, canonical/Vendor identity and `git diff --check`
  passed.
- The upstream-wide `cargo fmt --check` remains unusable as a clean gate because
  the pinned Vendor baseline contains unrelated formatting drift and a missing
  optional `src/ui/inline.rs`; no formatter changes were applied outside this
  boundary.

## Non-claims

- Existing-target replacement, multi-file resume, read/list/download, Viewer
  destination/progress UI and product opt-in are not implemented.
- No installed App or Agent was replaced or launched, no real user file was
  touched, and no Hermes/server, CI, dependency, database, push or deployment
  action was performed.
- Two-Mac file-transfer acceptance is unavailable and remains explicitly
  unverified. Per the current development-completion target, it is non-blocking;
  the Mac mini automatic Core lifecycle/build validation is the available local
  evidence.

## Next step

`host-file-transfer-native-read-list-download-lifecycle`: move the remaining
Native Host read/list/download path away from the unavailable external CM while
preserving descriptor ownership, bounded payloads and product default-off.
