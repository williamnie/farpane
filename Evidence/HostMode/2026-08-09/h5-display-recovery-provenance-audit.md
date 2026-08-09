# H5.3l Display-recovery provenance ABI audit

## Outcome

The pinned Rust monitor service is the only valid display-reconfiguration
authority, but the current Host event route cannot preserve that cause through
replacement-route convergence. This checkpoint freezes the smallest typed,
fail-closed provenance contract before changing the shared Host ABI. It does
not implement the ABI, emit display evidence, perform a real display change,
or claim a section 15.2 item 7 pass.

## Key evidence

- Display-info inequality, negotiated-codec change, and a joining subscriber
  each exit the same native service callback with `SWITCH`. Every retry gets
  fresh connection and codec epochs, so freshness alone cannot identify the
  originating cause.
- Native `run_native` currently passes literal display revision `1` on every
  route. Swift strictly orders route epochs, but its media control has only an
  untyped optional `reason` and no previous-route or display generation.
- The process evidence owner has exact pending state for sleep and network,
  but no display acceptance state or callback. Recording an arbitrary
  `stopCapture -> startCapture -> reconfigure` sequence would therefore create
  false display-recovery evidence.
- The target keeps encoded-packet Host Media ABI v1 unchanged and bumps Host
  Control ABI v11 to v12 because callback event semantics change. Envelope
  schema v1 remains valid.
- Rust must emit `mediaDisplayReconfigureStarted` only after display-info
  inequality on the exact active route. Its nonzero boot-lifetime generation,
  previous route identity, and exact-next display revision must then appear as
  one typed provenance object on both replacement `startCapture` and
  `reconfigure` controls.
- Swift may persist completion only after strict marker/control correlation and
  after the exact replacement route is both desired and active with no pending
  route-owner work. Codec/subscriber/retry routes, duplicates, mismatch,
  failure, teardown, and counter exhaustion never write display evidence.

## Verification

- The executable audit reports `status=abi-checkpoint-required`, all 11 source
  evidence checks true, all 9 source locations present, and no missing
  evidence.
- The focused ScriptTest executes the audit and verifies current ABI versions,
  the frozen v12/v1 target split, the dedicated accepted event, and exact
  provenance on both replacement controls.
- This checkpoint changes only audit, test, evidence, and design documentation;
  it does not modify Rust, C, Swift product source, shared ABI, or wire schema.

## Remaining boundary

- Implement Host Control ABI v12 end to end, including Rust/header/shim/build
  gates, strict Swift decoding, generation/revision lifecycle, route
  convergence polling, evidence-owner drain, and negative tests.
- Implement the bounded recovery manifest validator and negative fixtures.
- On an installed Mac, perform a real display transition and then a fresh
  passed 600-second `1080p30` scenario-3 run on the same Host/build scope.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, real display/TCC/configuration, and secrets were
  not changed; nothing was pushed.
