# H6.3e5b Native Host read/list/download connection lifecycle

## Outcome

The dedicated file-transfer connection now owns the bounded Native Host
read/list/download lifecycle over the descriptor-relative snapshot owner.
Product file transfer remains disabled until a Viewer destination/progress API
and explicit product composition are implemented.

## Contract

- Virtual wire root `/` and relative `ReadDir`, `ReadEmptyDirs` and `AllFiles`
  requests are served only by the pinned Native Host owner. Upstream CM/path
  fallback remains available only when no Native Host is bound.
- A connection owns at most eight Native read jobs. Job identifiers must not
  collide with Native write jobs, upstream read jobs or CM jobs.
- Each job sends a snapshot-bound directory and bounded 128 KiB blocks. File
  open, confirmation and EOF revalidate device, inode, size and mtime.
- Modern overwrite detection pauses before every file and fails closed unless
  the peer explicitly skips, continues from zero or supplies an in-range
  `UInt32` offset for the matching file number.
- The timer polls only runnable jobs and confirmation explicitly re-arms it.
  Cancel, remote error, connection close and Host unbind release or reject all
  associated read handles deterministically.
- Native errors are stable rejected/unavailable values and never include a
  local path.

## Focused evidence

- Real-filesystem tests cover virtual-root listing, recursive files and empty
  directories, exact bounded suffix streaming, skip and offset decisions,
  snapshot replacement and Host unbind.
- A connection-level test covers fail-closed mapping of wire confirmation
  variants, including malformed and mismatched decisions.
- The connection layer is carried by an independent canonical patch. Bootstrap
  applied it idempotently twice, and a clean reverse/forward replay produced a
  byte-identical final source.
- The machine audit reports all 14 evidence checks and all 10 source anchors
  present.

## Verification

- Focused Native read Rust tests: 4/4 passed.
- Full `rdn-native-core,rdn-native-host` Rust library suite: 215/215 passed.
- Full ScriptTests: 148/148 passed.
- Fresh arm64 Release Core built successfully as an arm64 Mach-O dylib; Swift
  tests loading that exact Core: 924/924 passed.
- Swift Release build, owned-source `rustfmt --check`, Python compilation,
  canonical/Vendor identity, patch replay, idempotent bootstrap,
  `git diff --check` and secret-candidate scan passed.

## Non-claims

- There is still no Viewer destination/progress API, product UI or explicit
  App/Agent file-transfer opt-in. The capability remains off.
- Multi-file upload resume and replacement of existing upload targets remain
  unsupported.
- No installed app or GUI smoke was performed because the disabled product
  composition cannot exercise this connection lifecycle. No real user file,
  Hermes/server, CI, dependency, database, push or deployment state changed.
- Two-Mac listing/download acceptance remains unavailable and explicitly
  unverified; it is non-blocking under the current development-only target.

## Next step

`host-file-transfer-viewer-destination-progress-api-contract`: define the
Viewer-side destination admission, progress/cancellation model and default-off
composition boundary before adding product UI.
