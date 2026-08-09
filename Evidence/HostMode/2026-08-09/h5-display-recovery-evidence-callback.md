# H5.3m Display-recovery provenance and evidence callback

## Outcome

The frozen H5.3l contract is implemented end to end. Host Control ABI is now
v12 while the Host event envelope remains v1 and the encoded-packet Host Media
ABI remains v1. The pinned RustDesk monitor service emits one typed
`mediaDisplayReconfigureStarted` marker only after display-info inequality on
the exact active route. The replacement route consumes that marker once and
attaches identical previous-route provenance to both `startCapture` and
`reconfigure`.

Swift strictly decodes and correlates the marker and both controls. Display
evidence is completed only after the exact replacement route is simultaneously
desired and active with no pending route-owner operation. Generic codec,
subscriber, and service retries never synthesize display evidence. This step
implements observation and evidence wiring; it does not claim a real display
transition or section 15.2 item 7 pass.

## Key evidence

- Rust keeps per-display revision and pending-provenance state. Marker
  generation, replacement connection/codec epochs, and display revision use
  checked monotonic allocation; stale routes, duplicates, and exhaustion fail
  closed.
- Only the display-info inequality branch marks the exact active route. Codec
  and subscriber `SWITCH` branches remain generic.
- `startCapture` and `reconfigure` carry the same typed provenance. A generic
  retry preserves the last display revision and carries no provenance.
- Swift rejects Boolean/fractional counters, malformed marker payloads, stale
  replacement epochs, non-exact-next display revision, and mismatched
  start/reconfigure provenance.
- The process evidence owner retains one exact pending display acceptance.
  Failure, timeout, mismatch, cancellation, or unavailable output discards it
  without writing.
- Product convergence polling is bounded and reports completion only when the
  exact route is desired and active and `pendingOperationCount == 0`.
- Teardown drains the display producer before releasing the shared evidence
  writer. Evidence failure remains observation-only and cannot change media
  routing or Host lifecycle.

## Verification

- Rust bridge tests: 35 passed, 0 failed.
- Fresh arm64 Release core built successfully.
- Full Swift suite against the fresh core: 856 passed, 0 skipped, 0 failed.
- ScriptTests: 47 passed, 0 failed.
- arm64 Swift Release build completed successfully.
- Display provenance audit reports `display-callback-implemented`, 10/10
  evidence checks, 9/9 source locations, and no missing evidence.
- Recovery performance audit reports `display-callback-implemented`, 12/12
  evidence checks, all source locations present, and no missing evidence.
- Canonical RustDesk and hbb_common patches reverse-apply cleanly; source and
  patch diffs pass whitespace checks.

## Remaining boundary

- Implement the bounded recovery manifest validator and negative fixtures.
- On an installed Mac, perform a real display transition and then a fresh,
  passed 600-second `1080p30` scenario-3 run on the same Host/build scope.
- Sleep/wake and network-path recovery likewise still need their installed-Mac
  transition plus post-recovery run. Section 15.2 item 7 remains open.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, real display/TCC/configuration, and secrets were
  not changed; nothing was pushed.
