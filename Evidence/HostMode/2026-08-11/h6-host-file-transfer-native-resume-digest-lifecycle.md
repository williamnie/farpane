# H6.3e4b Native Host single-file resume/digest lifecycle

## Outcome

Authenticated dedicated file-transfer connections can now resume one Native
Host file from a durable, descriptor-validated checkpoint. Product callers
remain disabled; multi-file resume and existing-target decisions remain outside
this boundary.

## Contract

- Resume is accepted only for one file whose expected size fits the protocol's
  `UInt32` offset. Declared size and modified time must match exactly.
- Admission atomically reserves every staging path in the owner. A second job
  cannot write or resume the same partial until the first job drops.
- Each write stores expected size, modified time, committed offset and SHA-256
  prefix digest in a fixed-size descriptor xattr, then calls `sync_all` before
  advancing the recoverable offset.
- Resume opens only the existing private `0600`, current-owner, single-link
  regular staging file through the pinned root descriptor. It recomputes the
  whole committed prefix and rejects missing, malformed, mismatched or tampered
  state.
- Bytes beyond the durable checkpoint are truncated before append. A shorter
  file is rejected instead of advertising an unsafe offset.
- Connection drop/job Drop preserves a non-empty verified partial. Explicit
  cancel, remote error, write failure and failed finish remove current staging.
  Host unbind blocks the old job while leaving a durable partial available to a
  future bound owner.
- The connection sends the verified offset in `OffsetBlk`; it no longer replies
  with a constant zero for a valid resume request.

## Focused evidence

- A three-byte checkpoint resumes at offset three and commits exact contents.
- Prefix tampering and exact metadata mismatch reject and remove staging.
- Explicit abort removes a checkpointed partial; unbind rejects the old job but
  preserves the prior checkpoint.
- Owner reservations are atomic, release on Drop, and prevent concurrent jobs
  from sharing a staging path.
- Canonical Host sources match the vendor checkout, and a dedicated zero-context
  connection patch is replayed and reverse-checked by bootstrap.

## Verification

- Focused resume/reservation Rust tests passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 204/204 passed.
- `rdn-native-core`-only release check passed, preserving the Viewer-only
  feature boundary.
- Fresh arm64 Core build succeeded; Swift tests loading that Core: 924/924
  passed; full ScriptTests: 145/145 passed; Swift release build succeeded.
- All ten H6 file-transfer audits, canonical bootstrap/reverse applicability,
  canonical/vendor source identity, Python compilation and `git diff --check`
  passed.

## Non-claims

- Multi-file resume, existing-target/overwrite decisions, read/list/download,
  Viewer destination/progress UI and product opt-in are not implemented.
- No installed App, real user file, Hermes/server change, push, deploy or
  two-Mac acceptance was exercised.
- Per the 2026-08-11 development-completion scope, unavailable two-Mac checks
  remain explicitly unverified but do not block automatic development steps.

## Next step

`host-file-transfer-native-existing-target-decision-lifecycle`: define a
fail-closed, no-replace decision contract for an already existing final target
without weakening descriptor ownership, resume integrity or cleanup guarantees.
