# H6.3d1 Host descriptor-relative receive-root primitive

## Outcome

FarPane now has a macOS Native Host-only primitive that admits an existing
private receive root and keeps all create/resume traversal relative to the
admitted directory descriptor. Replacing the original path after admission
cannot redirect later file creation.

This is a security building block, not product enablement. No Native Host
file-service owner calls it yet, and App and HostAgent still do not opt into
file transfer. H6.3d2 has since added descriptor-relative safe mutations.

## Contract

- Root admission starts from `/` and opens every absolute component with
  `openat(O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)`.
- Root-owned ancestors must belong to root or the current euid and must not be
  group/world writable; the final receive root must belong to the current euid
  with exact mode `0700`.
- Relative targets reject empty, absolute, NUL, `.`, `..`, repeated separator,
  and trailing separator forms.
- Missing nested directories are created with `mkdirat`, reopened no-follow,
  and validated as current-euid `0700` directories.
- New files use descriptor-relative `O_CREAT|O_EXCL|O_NOFOLLOW`, are forced to
  `0600`, and must be current-euid, single-link regular files.
- Resume uses descriptor-relative `O_RDWR|O_NONBLOCK|O_NOFOLLOW` and accepts
  only current-euid, `0600`, single-link regular files.
- Errors are fixed enums and do not embed paths or raw OS error text.

## Focused evidence

The five real-filesystem tests cover root symlink/mode rejection, nested private
creation, relative/absolute/symlink escape rejection, resume hard-link/mode
rejection, and root-path replacement after descriptor admission. The initial
stub run failed 0/5 as expected; the implemented run passed 5/5.

The path-replacement test admits `trusted`, renames that directory, replaces the
old path with a symlink to `outside`, and then creates through the retained root
owner. The file appears only in the renamed original directory, proving the
operation no longer resolves the replaced path.

## Verification

- Focused Native Host safe-root tests: 5/5 passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 185/185 passed.
- Release `rdn-native-core`-only Rust check passed, confirming the Host-only
  module is absent when `rdn-native-host` is not selected.
- Fresh arm64 Core build succeeded; Swift tests loading that Core: 924/924
  passed; full ScriptTests: 139/139 passed; release Swift build succeeded.
- Machine audit requires feature isolation, canonical/vendor byte identity,
  no-follow descriptor traversal, exact modes/ownership/link count, focused
  tests, bootstrap source verification, product default-off, and absence of a
  Native Host file-service owner.
- Canonical bootstrap/source identity and Python compilation passed; final diff
  and sensitive-assignment checks are recorded at local commit.

## Non-claims

- Existing upstream/CM path-based file transfer is unchanged.
- This H6.3d1 evidence does not claim the later H6.3d2 mutations were part of
  the original five-test boundary.
- H6.3e1 has since added the Native Host file-service owner and H6.3e3 has
  connected safe mutations; native write jobs and Viewer
  destination/overwrite/progress UI remain absent.
- No installed App, real user file, or two-Mac acceptance was exercised.

## Next step

H6.3d2 completed safe-root mutations, H6.3e1 composed the owner core, H6.3e2
configured its immutable root, and H6.3e3 connected safe mutations. Continue
with `host-file-transfer-native-write-job-lifecycle`.
