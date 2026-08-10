# H6.3e5a Native Host descriptor-relative read/list snapshot primitive

## Outcome

The Native Host file-service owner now provides the bounded, descriptor-relative
read/list snapshot layer required by a future connection-owned download sender.
The network lifecycle and product capability remain disabled.

## Contract

- Root and relative directory listing stays under the already admitted root
  descriptor. Each enumeration obtains an independent directory open-file
  description with `openat(dirfd, ".", O_DIRECTORY | O_NOFOLLOW)` before
  `fdopendir/readdir`, so repeated reads do not share a directory cursor.
- Only current-euid exact `0700` directories and exact `0600`, single-link
  regular files are exposed. Symlinks, unsafe modes, type confusion and names
  that cannot be represented as UTF-8 fail closed.
- Private `*.farpane-part` staging entries are neither listed nor accepted as
  direct snapshot targets.
- Immediate and recursive enumeration is bounded to 1,024 entries and 1 MiB of
  path metadata; recursion is bounded to 64 levels.
- A file snapshot stores the descriptor-relative path plus device, inode, size
  and modification time. `openat(O_RDONLY | O_NOFOLLOW)` revalidates all fields
  before returning a read handle, so a replacement after enumeration is
  rejected.

## Focused evidence

- Repeated root listings preserve independent cursors, filter hidden files when
  requested, and never expose private staging.
- Recursive snapshotting reports deterministic relative names and sizes, and
  still reads the admitted inode after the original root path is replaced by an
  external symlink.
- A same-name safe replacement is rejected by snapshot identity; symlinks,
  broad-mode files and direct staging requests also fail closed.
- A directory with 1,025 otherwise safe files is rejected before returning a
  partial listing.

## Verification

- Focused Native owner Rust tests passed, including all four new read/list
  snapshot cases.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 211/211 passed.
- Full ScriptTests: 147/147 passed; the new machine audit reports all 10
  evidence checks and all 7 source anchors present.
- Fresh arm64 Release Core built successfully as a thin arm64 linker-signed
  Mach-O dylib; Swift tests loading that exact Core: 924/924 passed.
- Swift Release build, owned-source `rustfmt --check`, Python compilation,
  canonical/Vendor identity, idempotent bootstrap and `git diff --check`
  passed.

## Non-claims

- `ReadDir`, `ReadAllFiles` and server-to-client `Send` are not yet routed to
  this owner. There is no Native read-job timer, block/digest/done sender or
  Viewer destination/progress UI in this checkpoint.
- App and Agent still do not opt into file transfer. No installed application,
  real user file, Hermes/server, CI, dependency, database, push or deployment
  state is changed.
- Two-Mac file-transfer acceptance remains unavailable and explicitly
  unverified; it is non-blocking under the current development-only target.

## Next step

`host-file-transfer-native-read-list-download-connection-lifecycle`: route the
dedicated file-transfer connection through this snapshot owner and add bounded
read jobs with explicit confirmation, cancellation and teardown.
