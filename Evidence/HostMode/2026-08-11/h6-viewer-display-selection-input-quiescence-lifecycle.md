# H6.4e Viewer display-selection input quiescence lifecycle

## Outcome

The live Viewer now has one product-owned input boundary for display selection.
Selection releases held pointer/keyboard state before Core admission and blocks all
new normal, IME, and exclusive-keyboard input until an exact successful terminal
event is also reflected by the current revisioned display catalog. Viewer ABI remains
v16 and Host ABI remains v17.

## Implemented contract

- `ViewerDisplaySelectionInputOwner` admits only an online entry from the current
  available catalog, allocates strictly monotonic positive command IDs, and keeps at
  most one local pending request.
- Quiescence occurs before the ABI call. A synchronous Core rejection rolls back only
  quiescence introduced by that unadmitted attempt; a prior fail-closed pause remains.
- Stale/mismatched terminal events are ignored. Typed failure clears the pending
  request but keeps input paused so window focus or exclusive-keyboard intent cannot
  reopen input.
- Success resumes only after the exact command identity and current
  `connectionEpoch + catalogRevision + selected displayIndex` all match. Callback
  order is tolerant: a matching success may wait for its catalog projection.
- `ViewerMetalView` drops pending pointer motion, releases held buttons and ordinary
  keys, and gates pointer, scroll, keyboard, command, text, and marked-text paths.
  `ExclusiveKeyboardController` releases captured keys, preserves user intent, and
  refuses focus-driven resume while the display gate is closed.
- App callback routing is scoped to the current Core generation and product attempt.
  Replacement Core owners inherit an existing pause; teardown stops the retiring
  authority without resuming it.
- No visible display selector was added in this step. No wire, ABI, Hermes, CI,
  dependency, database, installation, or running GUI state changed.

## Verification

- RED: focused Swift tests failed because the selection input owner and result types
  did not yet exist.
- GREEN focused owner/product contract tests: 6/6.
- Focused H6.4 ScriptTest: 1/1.
- H6.4 ownership audit: `input-quiescence-implemented-selector-pending`, with 12/12
  evidence checks, the single expected selector gap, and no anchor drift.
- Full Swift tests: 1006 executed, 4 environment-dependent tests skipped, 0 failures.
- Full ScriptTests: 181/181.
- Fresh isolated arm64 release build: passed.
- `git diff --check`: passed.

## Remaining boundary

Next is `viewer-display-selector-product-lifecycle`: present the normalized catalog,
route an explicit user selection into the prepared action, and expose pending/failure
state without treating display names as identity. Dual-Mac display, scale, rotation,
hot-plug, picture, and input acceptance remain unverified and nonblocking for the
single-Mac development scope.
