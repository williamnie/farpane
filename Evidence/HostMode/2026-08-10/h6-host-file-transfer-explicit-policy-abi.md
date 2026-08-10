# H6.3a Host file-transfer explicit-policy ABI seam

## Outcome

Host Control ABI v16 can represent one dedicated file-transfer permission while
remaining product-default-off. Existing App and Agent call sites do not opt in.
This step does not add a Viewer file API/UI, Home switch, clipboard file promise,
or claim end-to-end file transfer.

## Key evidence

- `RdnHostCreateOptions.enable_file_transfer` and
  `HostServerConfiguration.fileTransferEnabled` are independent from all six
  clipboard directions; the Swift default is `false`.
- Rust copies the create-time Boolean into the Host lifetime, writes an exact
  `enable-file-transfer=Y/N` before identity/network startup, and reopens the
  private options file to require the same value.
- Missing or stale persisted policy returns the existing storage failure before
  the network runtime is created.
- Pinned upstream handles a dedicated `FileTransfer` login and checks
  `OPTION_ENABLE_FILE_TRANSFER` before assigning that connection scope.
- `enable-audio` remains unconditionally `N`.
- Machine audit:
  `Scripts/audit-host-file-transfer-explicit-policy-abi-contract.py`.

## Verification

- RED: the focused Swift policy test failed to compile before implementation
  because `HostServerConfiguration` had no `fileTransferEnabled` member or
  initializer argument.
- Focused Rust file-policy readback test: 1/1 passed.
- Full pinned Rust `rdn-native-core,rdn-native-host` release suite: 180/180
  passed.
- Fresh arm64 Core build completed and published to
  `Build/CoreBridge/arm64/liblibrustdesk.dylib`; symbol gates passed.
- Full Swift suite loading that fresh Core: 924/924 passed.
- Full ScriptTests: 136/136 passed.
- `swift build -c release` completed.
- The H6.3a machine audit reports
  `host-file-transfer-abi-capable-product-default-off`, all 11 evidence checks
  and all 10 source anchors present.
- Canonical/vendor Host bridge mirror, Python compilation, bootstrap replay,
  and `git diff --check` passed.

## Explicit non-claims

- File transfer is not product-enabled.
- Viewer file selection, progress, cancellation, and destination UI do not
  exist yet.
- Clipboard file promises remain disabled.
- Two-Mac acceptance is not complete and is no longer a development blocker
  while only the Mac mini is available.

## Next step

`host-file-transfer-security-boundary-audit`: inspect and machine-record the
pinned upstream path traversal, symlink, filename, size, overwrite, and write
destination boundaries before adding any product opt-in.
