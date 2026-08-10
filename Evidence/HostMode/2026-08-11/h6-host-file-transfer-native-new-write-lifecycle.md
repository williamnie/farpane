# H6.3e4a Native Host new-file write-job lifecycle

## Outcome

Authenticated dedicated file-transfer connections now own bounded Native Host
new-file write jobs without an external Connection Manager. Product callers
remain disabled, and resume/overwrite/read jobs remain outside this boundary.

## Contract

- Admission requires file number zero, 1–1,024 real file entries, at most
  1 MiB of path metadata, unique strict-relative destinations, exact declared
  total size, and at most eight jobs per connection.
- Each file is created through the descriptor-backed owner as a private
  same-parent `*.farpane-part` staging file. Remote mutations cannot address
  that reserved namespace.
- Raw and compressed blocks retain the shared 128 KiB wire and decoded hard
  limit. File numbers are monotonic and per-file/whole-job byte totals must
  match exactly.
- File transition and final Done set the declared mtime, call `sync_all`, and
  commit with descriptor-relative `RENAME_EXCL`; existing destinations are
  never replaced.
- Cancel, remote error, connection drop, Host unbind and write failure close
  the current handle and remove only uncommitted staging. Previously committed
  files retain upstream per-file completion semantics.
- Exact new-file digest metadata receives offset zero. Resume and overwrite
  are rejected with fixed path-free errors for the next isolated boundary.
- Only a process with no Native Host retains upstream CM fallback. A live but
  unavailable/unbound Host fails closed.

## Focused evidence

- Multi-file raw/compressed write commits exact contents and removes staging.
- Wire/decoded overflow, wrong order, size overflow, traversal, duplicates and
  resume are rejected without a committed target.
- Dropping a two-file job preserves the first committed file while removing
  the second staging file.
- Unbinding the Host invalidates an admitted job and Drop removes its staging.
- Machine audit checks owner, connection, patch/bootstrap, product-off and
  explicit resume/overwrite non-claims.

## Verification

- Focused Native Host new-file write-job tests: 4/4 passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 198/198 passed.
- `rdn-native-core`-only release check passed, keeping Host write ownership out
  of the Viewer/Core-only feature boundary.
- Fresh arm64 Core build succeeded; Swift tests loading that Core: 924/924
  passed; full ScriptTests: 144/144 passed; Swift release build succeeded.
- All nine H6 file-transfer audits, canonical bootstrap/reverse applicability,
  canonical/vendor source identity, Python compilation and `git diff --check`
  passed.

## Non-claims

- Resume offset/digest sidecar, overwrite confirmation and existing-target
  replacement are not implemented.
- Directory listing, download/read jobs, Viewer destination/progress UI and
  product opt-in are not implemented.
- Crash-start orphan staging cleanup is not claimed; product remains off.
- No App/Agent launch, installed App, real user file, Hermes change, push or
  two-Mac acceptance was exercised.

## Next step

`host-file-transfer-native-resume-digest-lifecycle`: define stable staging
identity and exact offset/digest confirmation without weakening no-follow,
no-replace, size or teardown guarantees.
