# H6.3d2 Host descriptor-relative safe-root mutations

## Outcome

The macOS Native Host-only receive-root primitive now supports descriptor-
relative directory creation, safe file removal, empty-directory removal, and
atomic no-replace rename. All operations remain pinned to the root descriptor
admitted by H6.3d1.

This is still a security primitive, not product enablement. No Native Host
file-service owner calls these methods, and App/HostAgent still do not opt into
file transfer.

## Contract

- Directory creation resolves the parent below the admitted descriptor, uses
  `mkdirat`, forces exact mode `0700`, reopens no-follow, and revalidates owner
  and mode.
- File removal uses `fstatat(AT_SYMLINK_NOFOLLOW)` and accepts only a current-
  euid, exact `0600`, single-link regular file before `unlinkat`.
- Directory removal opens the target with `O_DIRECTORY|O_NOFOLLOW`, requires a
  current-euid exact `0700` directory, and uses `unlinkat(AT_REMOVEDIR)` so a
  non-empty directory fails closed.
- Rename validates the source as either the private regular-file contract or a
  current-euid exact `0700` directory, then uses macOS
  `renameatx_np(RENAME_EXCL)` to reject destination replacement atomically.
- Recursive removal is deliberately absent.
- Errors remain fixed enums and do not embed paths or raw OS error text.

## Focused evidence

Five new real-filesystem tests cover the allowed create/remove path, symlink
and hard-link rejection, type confusion and non-empty directory rejection,
no-replace rename with inode preservation, unsafe source rejection, and root-
path replacement after descriptor admission.

The root-replacement test admits `trusted`, renames it, replaces the original
path with a symlink to `outside`, then creates, renames, and removes through the
retained root owner. No mutation reaches `outside`.

## Verification

- Focused safe-root suite: 10/10 passed (the original five H6.3d1 tests plus
  five H6.3d2 mutation tests).
- Full `rdn-native-core,rdn-native-host` Rust suite: 190/190 passed.
- `rdn-native-core`-only release check passed, confirming the Host-only module
  is absent without `rdn-native-host`.
- Fresh arm64 Core build succeeded; Swift tests loading that Core: 924/924
  passed; full ScriptTests: 140/140 passed; release Swift build succeeded.
- The machine audit requires macOS Host feature isolation, canonical/vendor
  byte identity, descriptor-relative no-follow mutations, private ownership and
  mode checks, no-replace rename, focused tests, product default-off, deliberate
  absence of recursive removal, and absence of a Native Host file-service owner.

## Non-claims

- Existing upstream/CM path-based file transfer is unchanged.
- No Native Host file-service owner, Viewer destination/overwrite/progress UI,
  or end-to-end file transfer exists.
- No installed App, real user file, or two-Mac acceptance was exercised.

## Next step

`host-file-transfer-native-service-owner`: compose the bounded block envelope
and descriptor-relative root primitives behind the existing default-off Host
policy without turning on product callers.
