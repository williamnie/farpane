# H6.3e2 Host immutable receive-root config contract

## Outcome

Host Control ABI v17 now pairs explicit file-transfer permission with one
immutable receive-root string. Rust admits that root into the H6.3e1 owner
during `rdn_host_create` and retains the descriptor-backed owner for the Host
lifetime.

The product remains disabled: current App and HostAgent callers use the default
`false` permission and nil root, and connection dispatch is not wired.

## Contract

- C `RdnHostCreateOptions.file_transfer_receive_root` is copied during create.
- Swift `HostServerConfiguration.fileTransferReceiveRoot` defaults to nil and
  projects nil as an empty C string.
- Disabled permission requires an empty root; enabled permission requires a
  non-empty root. A mismatch returns validation before the process singleton
  claim or filesystem access.
- After the singleton claim, the enabled root must pass descriptor-relative,
  no-follow, current-euid, exact-`0700` admission. Failure releases the claim
  and returns storage failure.
- A successfully admitted owner is stored on `RdnHost` until destroy; later
  file operations do not need to resolve the original path again.
- Explicit file transfer on a non-macOS Host returns not-supported.

## Focused evidence

- The real-filesystem owner configuration test proves false/nil and true/safe
  root are the only accepted pairs; false/root and true/nil fail closed.
- The Swift configuration test proves default nil and explicit root projection.
- The machine audit verifies ABI v17 across C/Rust/Swift, validation ordering,
  owner retention, singleton release on admission failure, product default-off,
  and the later mutation-only connection dispatch with write jobs still open.

## Verification

- Focused Native Host file-root/owner suite: 13/13 passed.
- Focused Swift CoreBridge contract suite against the fresh Core: 43/43 passed.
- Full Native Host/Core Rust suite: 193/193 passed.
- Full Swift suite against the fresh arm64 Core: 924/924 passed.
- Full machine-audit ScriptTests suite: 142/142 passed.
- Fresh arm64 Core build and Swift release build passed.

## Non-claims

- H6.3e3 has since routed safe mutation responses to the owner, and H6.3e4a
  later added bounded new-file write jobs, cancellation and teardown. Resume,
  overwrite, read/list, Viewer destination/progress UI and end-to-end transfer
  remain open.
- No App/Agent opt-in, installed App, real user file, Hermes change, push, or
  two-Mac acceptance was exercised.

## Next step

H6.3e3 connected safe mutations and H6.3e4a added bounded new-file writes.
Continue with `host-file-transfer-native-resume-digest-lifecycle`, while
leaving product callers disabled.
