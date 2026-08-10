# H6.3b Host file-transfer security boundary audit

## Outcome

The pinned file service has useful path-name and existing-symlink guards, but
FarPane Native Host file transfer is not product-ready. The audit keeps H6.3a's
default-off policy authoritative and records the exact security and runtime
gaps that must be closed before any UI or bootstrap opt-in.

## Established guards

- Dedicated `FileTransfer` authentication checks `OPTION_ENABLE_FILE_TRANSFER`
  before assigning the connection scope.
- The authorized scope admits file actions/responses rather than screen/input
  traffic.
- Relative transfer entry names reject NUL, `..`, and absolute paths; one bad
  entry rejects the whole file list.
- Existing symlink components below a selected base are rejected with
  `symlink_metadata`.
- App and Agent do not pass `fileTransferEnabled`; the release feature list
  omits `unix-file-copy-paste`.

## Open gaps

- H6.3c follow-up: compressed `FileTransferBlock` payloads now have matching
  128 KiB wire and decoded hard limits. This item is no longer open; it remains
  here as the audit finding that selected the H6.3c implementation boundary.
- Path validation followed by `File::create`/resume reopen has a documented
  symlink TOCTOU window; it is not descriptor/handle based.
- remove/create/rename paths only reject empty/NUL and are not constrained to a
  FarPane-owned destination root.
- Native Host intentionally drops the external CM receiver, while receive,
  remove, create, rename, and related writes still dispatch only through the CM
  channel. There is no in-process Native Host file-service owner.
- Destination selection, overwrite confirmation, progress/cancel UX, Viewer
  file API, and two-Mac acceptance remain absent.

## Verification

- Current machine audit status remains `audited-not-product-ready`; bounded
  blocks are now an established guard while the remaining safe-open/root,
  file-service owner, and product UX gaps stay open.
- Focused `hbb_common::fs` release tests: 14/14 passed, including relative and
  absolute traversal, NUL, full-list rejection, and symlink escape cases.
- Native Host connection scope tests: 4/4 passed.
- Native Host external-CM exclusion test: 1/1 passed.
- Full ScriptTests: 137/137 passed.
- Python compilation, `git diff --check`, canonical source readback, and secret
  scan passed.
- An initial ScriptTests invocation from `Vendor/rustdesk` failed before test
  collection because that cwd has no importable `Tests/ScriptTests`; rerunning
  the same discovery command from the repository root passed 137/137. This was
  a command-cwd error, not a product or test failure.

## Non-claims

- Product enablement is not safe yet.
- Native Host file transfer is not functional end to end.
- Existing symlink checks do not close races.
- File-promise clipboard support remains disabled.

## Next step

H6.3c completed the bounded-block envelope. The next boundary is
`host-file-transfer-safe-open-root`: close the documented symlink race and bind
all receive-side mutations to a FarPane-owned destination root before adding
the Native Host file-service owner.
