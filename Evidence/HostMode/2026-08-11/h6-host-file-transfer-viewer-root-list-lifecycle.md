# H6.3f2b2b Viewer root-list command/callback ABI lifecycle

## Outcome

Viewer ABI v10 now carries an exact-session, single-flight remote-root list
command and a bounded callback-scoped result. The product remains default-off
and there is still no destination or file I/O.

## Contract

- A positive request ID and exact active file-session epoch must pass active,
  authenticated, remote-permission and ready-sender gates. Only one request may
  be pending and it sends `ReadDir("/", include_hidden=false)`.
- Rust accepts only nonlocal/full/root responses, applies the owned 1,024-entry
  and 1 MiB structural envelope, and emits success or stable rejected/
  unavailable status without raw errors or remote paths.
- Callback entries and UTF-8 names live only during the synchronous callback.
  Swift copies every byte before queued delivery and independently validates
  ABI, epoch, request ID, UTF-8, byte-exact NFC, full case-fold collisions,
  separators, controls, private staging, types and directory size.
- Send failure, disconnect, worker exit and job teardown clear pending state;
  stale responses have no request to consume.

## Verification

- Focused Rust tests passed 3/3 and focused Swift tests passed 7/7. They cover
  command gates, real channel message shape, single-flight admission,
  success/rejected/unavailable callbacks, ownership, Unicode normalization and
  stable failure metadata. The full Rust suite passed 220/220.
- The machine audit proves ABI/shim/build symbol coverage, both validation
  layers, teardown, product non-opt-in and the remaining I/O gap.
- ScriptTests passed 153/153. The full Swift suite loaded the freshly built
  exact arm64 Core and passed 932/932. Rust Core arm64 and Swift Release builds,
  idempotent bootstrap replay, targeted rustfmt, Python compile and diff checks
  passed. Whole-crate `cargo fmt --check` remains unusable because upstream's
  configured `src/ui/inline.rs` is absent; the tracked bridge itself is clean.

## Non-claims

- There is no recursive manifest, destination descriptor owner, download start,
  progress mapping, conflict handling, file write or product UI.
- App and Agent do not opt in. The installed App is not started because this
  internal API has no product route.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changes. Two-Mac acceptance remains unverified and non-blocking.

## Next step

`host-file-transfer-viewer-destination-descriptor-owner`: establish a pinned,
session-bound local destination owner before any download command can write.
