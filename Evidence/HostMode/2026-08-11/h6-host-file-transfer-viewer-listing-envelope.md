# H6.3f2b2a Viewer remote-list structural envelope

## Outcome

Viewer Rust now has an owned, bounded and fail-closed remote-list structural
envelope. It remains internal and cannot send a list command, publish a
callback, access a destination or enable the product.

## Contract

- Empty listings are valid. Non-empty listings are capped at 1,024 entries and
  1 MiB of aggregate UTF-8 name metadata.
- Only regular files and zero-size directories are accepted. Links, drives,
  unknown types, hidden entries, unsafe names, path separators, control
  characters, private `*.farpane-part` names and ASCII case aliases fail closed.
- Accepted names are copied into Rust-owned `String` values before the upstream
  protobuf can be reused or destroyed.
- This structural layer does not claim complete Unicode NFC/case-fold handling.
  The future Swift manifest callback must revalidate the full H6.3f1 contract.

## Verification

- Focused Rust regressions passed 2/2 and cover owned Chinese UTF-8 names,
  empty listings and every structural rejection/size boundary. The full Rust
  suite passed 219/219.
- The machine audit proves the limits, copy boundary, rejection gates, ABI v9
  non-expansion and product non-opt-in.
- ScriptTests passed 152/152. The full Swift suite loaded the freshly built
  exact arm64 Core and passed 931/931. Rust Core arm64 and Swift Release builds,
  idempotent bootstrap replay, targeted rustfmt, Python compile and diff checks
  passed. Whole-crate `cargo fmt --check` remains unusable because upstream's
  configured `src/ui/inline.rs` is absent; the tracked bridge itself is clean.

## Non-claims

- There is no list command/callback ABI, list request dispatch, recursive
  manifest assembly, destination descriptor owner, transfer job or local I/O.
- App and Agent remain default-off. No installed App was started because this
  internal primitive has no product entry point.
- No real user file, Hermes/server, CI, dependency, database, push or deploy
  state changed. Two-Mac acceptance remains unverified and non-blocking.

## Next step

`host-file-transfer-viewer-destination-descriptor-owner`: the exact-session
list command/callback now exists; pin a safe local destination before I/O.
