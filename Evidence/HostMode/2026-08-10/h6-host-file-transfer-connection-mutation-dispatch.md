# H6.3e3 Native Host connection mutation dispatch

## Outcome

Authenticated dedicated file-transfer connections now route four bounded
mutation classes to the descriptor-backed Native Host owner: create directory,
remove private file, remove empty private directory, and same-parent no-replace
rename. The product remains disabled and write jobs remain outside this step.

## Contract

- The admitted owner is shared with the running Host broker through `Arc` and
  removed from the broker during unbind before connections can issue another
  mutation.
- A bound Host without an admitted owner, or a live Host while unbound, returns
  unavailable. Only a process without a live Native Host selects the existing
  upstream CM fallback.
- Connection dispatch remains inside the existing authenticated
  `file_transfer.is_some()` action scope.
- Rename accepts exactly one normal basename and derives the destination from
  the source parent; descriptor-relative `RENAME_EXCL` prevents replacement.
- Recursive directory removal remains unsupported and fails before lookup or
  mutation.
- Success uses the existing `FileTransferDone` response. Rejection and
  temporary unavailability use fixed path-free error strings.
- The connection change is replayable from
  `h6-file-transfer-mutation-dispatch.patch`; bootstrap applies or reverse-checks
  it and preserves non-native upstream behavior.

## Focused evidence

- A real-filesystem Rust test creates, renames, removes, and cleans a private
  tree through the adapter.
- The same test rejects traversal and recursive removal without touching the
  source, then proves bound success, rejected input, and missing-owner
  unavailable outcomes.
- The machine audit checks all four connection arms, response taxonomy,
  authenticated scope ordering, CM fallback, patch replay, owner bind/unbind,
  and the still-open write-job boundary.

## Verification

- Focused Native Host mutation adapter test: 1/1 passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 194/194 passed.
- Release `rdn-native-core`-only check passed, proving the Host mutation adapter
  remains absent from the Viewer/Core-only feature boundary.
- Fresh arm64 Core build succeeded; full Swift tests loading that Core: 924/924
  passed; full ScriptTests: 143/143 passed; Swift release build succeeded.
- Canonical bootstrap/reverse applicability, canonical/vendor source identity,
  Python compilation, all seven H6 file-transfer audits, and `git diff --check`
  passed.

## Non-claims

- H6.3e4a has since added Native Host new-file receive, block/done/error/cancel
  and teardown. This historical H6.3e3 evidence does not claim those were part
  of the mutation-dispatch boundary.
- Resume offset/digest and overwrite remain fail closed/not implemented.
- Directory listing, download/read jobs, Viewer destination/progress UI,
  product opt-in and end-to-end transfer are not implemented here.
- No App/Agent launch, installed App, real user file, Hermes change, push or
  two-Mac acceptance was exercised.

## Next step

H6.3e4a completed the bounded new-file write lifecycle. Continue with
`host-file-transfer-native-resume-digest-lifecycle`; read/list/download,
Viewer destination/progress UI and product opt-in remain open.
