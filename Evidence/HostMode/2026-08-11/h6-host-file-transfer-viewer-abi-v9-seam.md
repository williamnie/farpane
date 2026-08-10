# H6.3f2a Viewer file-transfer ABI v9 default-off seam

## Outcome

Viewer ABI v9 now freezes a bounded event/cancel/config seam for future file
transfer while keeping the product and network runtime disabled.

## Contract

- ABI v9 retains the existing clipboard APIs and adds a scalar, callback-scoped
  file event. No path, descriptor, byte pointer or raw protocol error crosses
  the callback.
- Configuration is an exact pair: ordinary Viewer sessions use `false/0`.
  Mismatched pairs fail validation. H6.3f2b1 subsequently connected the
  `true/nonzero` pair to a dedicated, product-disabled file session.
- Cancel requires a positive transfer ID and exact nonzero session epoch. The
  disabled, stale, inactive, unauthenticated and permission-denied cases return
  stable client error codes.
- Swift revalidates ABI, epoch/ID/sequence, enums, monotonic bounds, finite
  speed, conflict file number and exact completion before queued delivery.
  Disconnect closes file-event delivery before the Core disconnect.
- The dynamic shim and both Core build paths require the cancel symbol, so a
  partial ABI cannot load as v9.

## Verification

- Focused Rust seam test passed 1/1 and covers exact config-pair admission and
  cancel lifecycle. The full Rust suite passed 216/216.
- Focused Swift contract test passed 1/1 and covers default-off configuration
  and epoch-scoped cancel shape. The full Swift suite loaded the freshly built
  exact arm64 Core and passed 931/931.
- The machine audit checks ABI shape, scalar/path-free callback, pre-network
  fail-closed admission, Swift validation, symbol gates and product non-opt-in.
- ScriptTests passed 150/150. Rust Core arm64 and Swift Release builds passed;
  bootstrap replay was idempotent and the canonical/generated Viewer bridges
  matched byte-for-byte.

## Non-claims

- Rust does not produce file events and does not create a Viewer file-session
  event loop, destination descriptor owner, listing/download I/O or product UI.
- The enabled pair now establishes only the dedicated session/cancel runtime;
  product file transfer remains unavailable and App/Agent do not opt in.
- No App was installed or started. No real user file, Hermes/server, CI,
  dependency, database, push or deploy state changed.
- Two-Mac file-transfer acceptance remains unverified and non-blocking under the
  current development-only target.

## Next step

`host-file-transfer-viewer-list-command-callback-abi-lifecycle`: wire the owned
remote-list envelope to a default-off command/callback before download I/O.
