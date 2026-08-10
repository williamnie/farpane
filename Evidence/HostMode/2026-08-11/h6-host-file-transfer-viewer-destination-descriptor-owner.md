# H6.3f2b2c Viewer destination descriptor owner

## Outcome

CoreBridge now pins one pre-existing private destination directory to an exact
Viewer file-session epoch and exposes it only through an opaque lease and a
scoped descriptor callback. No download or file write path is enabled.

## Contract

- Initialization requires a positive epoch/token, an absolute standardized
  path, and `open(O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)` success.
- `fstat` must prove an euid-owned directory with exact `0700` permissions and
  a positive link count. The owner retains only descriptor, device/inode,
  epoch and token; it does not retain the selected path.
- Every borrow requires the exact lease and freshly revalidates descriptor
  identity, owner, type, permissions and link state. Permission drift and stale
  leases fail closed.
- Borrow holds the state lock through its callback. Exact-epoch teardown and
  deinitialization close the descriptor; stale or repeated teardown is inert.
- Replacing the selected pathname after initialization cannot redirect the
  pinned descriptor.

## Verification

- Four focused Swift tests cover valid borrow, invalid epoch/token, file,
  symlink and unsafe-mode rejection, permission drift, stale leases, exact
  teardown and pathname replacement while preserving the pinned inode.
- The machine audit proves open flags, descriptor-only state, fresh identity
  checks, scoped borrow, teardown/deinit closure, product non-opt-in and the
  absence of download/file-creation calls.
- Full `rdn-native-core,rdn-native-host` Rust library suite passed 220/220.
  ScriptTests passed 154/154. The full Swift suite loaded the freshly rebuilt
  exact arm64 Core and passed 936/936. Fresh arm64 Rust Core and Swift Release
  builds, Python compilation, machine audits and `git diff --check` passed.

## Non-claims

- There is no recursive remote manifest, download-start command, `openat`,
  staging file, conflict workflow, picker UI or product file-transfer opt-in.
- The App is not started because no product path reaches this internal owner.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changes. Two-Mac acceptance remains unverified and non-blocking.

## Next step

`host-file-transfer-viewer-recursive-manifest-lifecycle`: build a bounded,
exact-session recursive remote manifest before any download may start.
