# H6.4f Viewer display selector product lifecycle

## Outcome

The live FarPane Viewer now presents the normalized remote display catalog and routes
an explicit selection through the existing revisioned command/input-quiescence
lifecycle. The selector exposes pending and stable failure states without treating a
remote display name as identity. Viewer ABI remains v16 and Host ABI remains v17.

## Implemented contract

- The selector is present only for live Viewer sessions. Fixture playback does not
  expose a command that has no Core authority.
- Each menu item carries canonical `displayIndex` as its tag. The bounded remote name
  and geometry are presentation only; empty names receive a local ordinal fallback,
  and offline entries remain visible but disabled.
- Catalog projection is scoped by the current Core generation and product attempt.
  Selection is disabled until both an available catalog and `controlReady` authority
  exist.
- Pending selection disables the selector and shows a distinct progress state.
  Admission rejection, catalog change, connection closure, and remote selection drift
  map to stable user-facing failures without raw protocol diagnostics.
- A failed selection keeps input fail closed but leaves the selector retryable once
  control authority exists. A replacement Core inherits the pause and explicitly asks
  for a new selection rather than silently restoring input.
- Exact success updates the selected menu item through the authoritative catalog and
  resumes input through the H6.4e owner. Teardown does not reuse the retiring catalog.
- No wire, ABI, Hermes, CI, dependency, database, installation, or running GUI state
  changed.

## Verification

- RED: focused product contract tests failed on the absent selector callback and
  presentation update wiring.
- GREEN focused owner/presentation/product tests: 8/8.
- Focused H6.4 ScriptTest: 1/1.
- H6.4 ownership audit: `selector-implemented-development-audit-pending`, with 13/13
  evidence checks, no code gaps, and no source-anchor drift.
- Full Swift tests: 1008 executed, 4 environment-dependent tests skipped, 0 failures.
- Full ScriptTests: 181/181.
- Isolated fresh arm64 release build: passed.
- H6.4 audit and `git diff --check`: passed.

## Remaining boundary

Next is `multi-display-product-development-completion-audit`: audit H6.4 requirements
end to end and distinguish completed development from the dual-Mac display, scale,
rotation, hot-plug, picture, and input acceptance that remains unverified and
nonblocking under the current single-Mac scope.
