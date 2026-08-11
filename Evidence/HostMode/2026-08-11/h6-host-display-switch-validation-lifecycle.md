# H6.4d Host display-switch validation lifecycle

## Outcome

Host monitor display switching now validates the target against the Host's live
display-service inventory before any media service subscription or input-mapping
mutation. Rejected commands reassert the current canonical selection so the Viewer
terminal lifecycle does not remain pending. Viewer ABI remains v16 and Host ABI
remains v17.

## Implemented contract

- The wire display index must convert from signed `i32` to `usize`; negative targets
  fail before inventory lookup.
- The exact live inventory entry must exist and be online, with positive width/height,
  finite positive scale, and non-overflowing `x + width` / `y + height` bounds.
- Validation runs before `switch_display_to`, so rejection cannot add/subscribe a
  monitor service, change `display_idx`, or advance the macOS input-mapping generation.
- Rejection sends the current display through existing
  `make_display_changed_msg`/`SwitchDisplay`; the Viewer resolves the mismatched echo as
  typed `remoteSelectionDrift` rather than retaining a command indefinitely.
- A dedicated top-layer canonical patch is replayed by bootstrap and checked by the
  source verifier. No protobuf, Hermes, ABI, CI, dependency, database, installation,
  or running GUI state changed.

## Verification

- RED: the focused Rust test failed to compile only because
  `validate_monitor_display_switch_target` was absent.
- GREEN focused Rust test: 1/1.
- Full RustDesk connection tests: 38/38.
- Full RustDesk library tests: 239/239.
- Fresh arm64 Rust core build: passed.
- Full Swift tests against the built core: 1000/1000.
- Full ScriptTests: 181/181.
- H6.4 ownership audit: `host-validation-implemented-product-pending`, with no
  missing evidence or expected-gap drift.
- Bootstrap replay, source verifier, patch reverse applicability, diff checks, and
  fresh arm64 Swift release build: passed.

## Remaining boundary

Next is `viewer-display-selection-input-quiescence-lifecycle`: release held Viewer
input and block new input while a display selection is pending, then resume only after
an exact terminal success and current catalog tuple. The product display selector and
dual-Mac display/scale/rotation/hot-plug/input acceptance remain separate, unverified
boundaries and do not block further single-Mac development.
