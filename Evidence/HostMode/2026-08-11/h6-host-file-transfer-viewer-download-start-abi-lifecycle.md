# H6.3f2b2f Viewer download-start ABI lifecycle

## Outcome

Viewer ABI v12 now registers one bounded, path-free queued download lifecycle
against the exact completed recursive manifest. This is an internal seam only:
the product remains default-off and no download wire request or local file I/O
is performed.

## Key evidence

- `RDNFileTransferDownloadStart` contains only ABI version, session epoch,
  manifest request ID, transfer ID, file count and byte total. It contains no
  path, destination token, descriptor or borrowed pointer.
- Rust retains the exact completed manifest ID and its checked file/byte totals,
  then requires an active dedicated file session, exact epoch, authentication,
  remote file permission and a ready sender before registration.
- Registrations are connection-local, unique by positive transfer ID and capped
  at eight. Invalid, stale, duplicate, over-limit and mismatched manifest totals
  fail closed.
- Registration does not enqueue `Data::SendFiles`, a protocol message or any
  other wire action. It does not borrow the Swift destination lease and does not
  call `openat`, create staging entries or write bytes.
- Successful upstream cancel removes the matching registration. Job error/done,
  clear-all, disconnect, connect reset and worker exit also clear owned state.
- Swift projects only the exact scalar tuple from the validated download request;
  the destination lease remains owned by `ViewerFileTransferDestinationOwner`.
- The C header, shim loader/wrapper, Release build symbol gates and built-core
  contract all require `rdn_client_file_transfer_download_start`.
- The machine audit reports
  `viewer-download-start-abi-lifecycle-implemented-product-off`, all evidence and
  source anchors true, download wire/I/O false, product enablement false and
  two-Mac acceptance false.

## Verification

- Focused Rust regression: 1/1 passed.
- Full Rust library suite with `rdn-native-core,rdn-native-host`: 223/223 passed.
- Fresh arm64 Release Rust core built successfully and exported the new symbol.
- Built-core `HostBridgeContractTests`: 3/3 passed.
- Full Swift suite against the fresh core: 942/942 passed with no skips.
- Focused machine audit and audit unittest: 1/1 passed.
- Full ScriptTests: 157/157 passed.
- Product App smoke was not run: there is intentionally no App/Agent opt-in or
  product call route for this internal registration, so launching the GUI cannot
  exercise it and could interfere with the active Mac mini session.
- Two-Mac download, remote progress and file contents remain unverified and do
  not block this development-only milestone.

## Next step

`host-file-transfer-viewer-download-dispatch-progress-lifecycle`: separately
design and implement the actual wire dispatch plus progress/terminal mapping,
while retaining destination-descriptor ownership and descriptor-relative I/O as
explicit later gates.
