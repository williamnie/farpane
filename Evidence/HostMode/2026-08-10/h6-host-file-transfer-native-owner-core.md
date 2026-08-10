# H6.3e1 Native Host file-service owner core

## Outcome

`NativeHostFileServiceOwner` is now the only module-visible authority over the
macOS Native Host receive-root implementation. It owns the admitted root
descriptor and composes every safe create, resume, directory, remove, and rename
operation from H6.3d1/d2.

This is owner-core composition, not connection wiring or product enablement.

## Contract

- `NativeFileTransferRoot` and its methods are module-private; other Host code
  cannot bypass the owner and call the filesystem primitives directly.
- Owner construction admits exactly one existing private root and retains its
  descriptor for the owner lifetime.
- New-file, resume, directory create, file remove, empty-directory remove, and
  no-replace rename delegate to the established descriptor-relative contracts.
- Recursive directory removal returns the fixed
  `RecursiveRemovalUnsupported` error before any filesystem lookup or mutation.
- Errors remain fixed enums without paths or raw OS error text.

## Focused evidence

Two new real-filesystem tests exercise the full owner surface and prove that a
recursive remove request leaves a populated tree untouched. Together with the
ten H6.3d1/d2 tests, the focused suite is 12/12.

## Verification

- Focused Native Host file-root/owner suite: 12/12 passed.
- Full `rdn-native-core,rdn-native-host` Rust suite: 192/192 passed.
- `rdn-native-core`-only release check passed, confirming the owner module is
  absent without `rdn-native-host`.
- Fresh arm64 Core build succeeded; Swift tests loading that Core: 924/924
  passed; full ScriptTests: 141/141 passed; release Swift build succeeded.
- Machine audit verifies feature isolation, canonical/vendor byte identity,
  private root implementation, full owner delegation, pre-mutation recursive
  rejection, bootstrap replay, product default-off, and absence of receive-root
  configuration/connection dispatch.

## Non-claims

- H6.3e2 has since added the receive-root field; this H6.3e1 evidence does not
  claim it was present in the original owner-core boundary.
- H6.3e3 has since routed safe directory/file mutations to this owner, and
  H6.3e4a later added bounded new-file write jobs plus cancellation/teardown.
  Resume offset/digest, overwrite, read/list and Viewer UI remain open.
- No App/Agent opt-in, Viewer UI, installed App, real user file, Hermes change,
  push, or two-Mac acceptance was exercised.

## Next step

H6.3e2 completed the immutable receive-root contract, H6.3e3 connected safe
mutations, and H6.3e4a added bounded new-file writes. Continue with
`host-file-transfer-native-resume-digest-lifecycle`, keeping current product
callers disabled.
