# H6.3f2b1 Viewer dedicated file-session and cancel dispatch lifecycle

## Outcome

The ABI v9 enabled pair now owns a dedicated, product-disabled upstream file
session and an exact-epoch cancel dispatch. It does not start any file job or
access a local destination.

## Contract

- `false/0` preserves the desktop Viewer connection. `true/nonzero` selects
  upstream `FILE_TRANSFER`; mismatched pairs and any file-mode configuration
  that also enables a desktop clipboard direction fail before runtime mutation.
- File mode persists the exact epoch for the worker lifetime, skips desktop
  stream-configuration/TestDelay housekeeping, and never enables remote input.
  Authentication projects `authenticated` followed by `file-transfer-ready`.
- Worker exit and explicit disconnect clear authentication, input, file mode
  and epoch.
- Cancel requires positive values, active file mode, exact epoch,
  authentication, remote file permission and a ready sender. Success enqueues
  exactly one upstream `CancelJob`; failure returns a stable typed client code.

## Verification

- Focused Rust tests passed 2/2, exercise mode-pair admission and read the real
  channel to prove stale epoch, remote permission and exact cancel dispatch
  behavior. The full Rust suite passed 217/217.
- The machine audit checks pre-mutation admission, dedicated upstream mode,
  no-input/no-housekeeping lifecycle, teardown, cancel gates and product
  non-opt-in.
- ScriptTests passed 151/151. The full Swift suite loaded the freshly built
  exact arm64 Core and passed 931/931. Rust Core arm64 and Swift Release builds,
  idempotent bootstrap replay, rustfmt, Python compile and diff checks passed.

## Non-claims

- There is no list/download start command, remote manifest event, progress/job
  terminal mapping, destination descriptor owner, local file I/O or product UI.
- App and Agent do not opt in. No installed App was started because the product
  cannot exercise this internal session slice.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changed. Two-Mac acceptance remains unverified and non-blocking.

## Next step

`host-file-transfer-viewer-list-command-callback-abi-lifecycle`: wire the owned
remote-list envelope to a default-off command/callback before download I/O.
