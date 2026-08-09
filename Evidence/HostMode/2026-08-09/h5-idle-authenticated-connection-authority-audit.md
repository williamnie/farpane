# H5.3e Idle authenticated-connection authority audit

## Outcome

The idle matrix blocker is now a machine-audited shared-contract checkpoint,
not an inference left to the performance scripts. The canonical Rust authority
already exists: `AUTHED_CONNS` contains every authenticated connection type,
is populated only by authenticated admission, is pruned by `AuthedConnID` RAII
drop, and is read under the same mutex by the native Host sleep-assertion
policy.

That all-type count currently stops inside RustDesk server code. Host snapshot
schema v7, strict Swift decoding, Agent projection/XPC, runtime-state schema v1,
and the idle validator do not carry it. Therefore the idle summary correctly
continues to report `allAuthenticatedConnectionsProvenAbsent=false`, and the
H5.3d matrix correctly refuses to accept it as section 15.2 item 1.

## Machine audit

`Scripts/audit-host-idle-authenticated-connection-authority.py` verifies nine
current-state invariants and emits
`farpane-host-idle-authenticated-connection-authority-audit` schema v1 with
`status=checkpoint-required`. It fails if any expected authority, lifecycle,
missing-field boundary, or downstream positive-proof gate drifts.

The audit freezes the next shared checkpoint as:

- Host ABI v11 and Host snapshot schema v8;
- snapshot field `authenticatedConnectionCount`, read from the complete
  mutex-protected `AUTHED_CONNS` list without filtering by connection type;
- strict Swift `UInt64` decode, Agent projection preservation, and nested XPC
  payload schema v8; the outer XPC wire version need not change;
- runtime-state schema v2 with an optional count sourced from either the
  legacy HostCore snapshot or one coherent background Agent XPC projection;
- ready idle records require the count to be present and exactly zero;
- `allAuthenticatedConnectionsProvenAbsent` must be derived from every
  accepted record and must never be hardcoded.

`activeSession == nil`, no media route/pipeline, and zero sleep assertions are
explicitly forbidden substitutes: file transfer, port forwarding, terminal,
camera, or another authenticated non-screen connection could exist without
those signals.

## Verification

- `Scripts/bootstrap-rustdesk-core.sh`: pinned commit
  `6c578292e8ebbbec708b76986ba8c4bc7c509747`, canonical patch clean reverse
  check passed.
- `python3 Scripts/audit-host-idle-authenticated-connection-authority.py`:
  `checkpoint-required`, 9/9 current evidence checks true, no missing evidence,
  all source locations resolved.
- `python3 -m unittest Tests.ScriptTests.test_host_idle_authenticated_connection_authority_audit`:
  1 test, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  44 tests, 0 failures.
- Python compile and `git diff --check`: exit 0.

No product source or shared ABI/schema changed in this audit-only step, so no
App/Core build or runtime behavior is claimed.

## Remaining boundary

- Implement the frozen ABI/snapshot/XPC/runtime-state checkpoint as a separate
  high-risk step with Rust lifecycle, strict Swift decoder, Agent projection,
  XPC round-trip, runtime writer, idle validator, built-core, and source
  integrity tests.
- The background and legacy runtime-state call sites must select exactly one
  coherent count authority; combining values from different snapshot epochs is
  forbidden.
- A real 600-second Host-ready/no-connection installed-machine run remains
  mandatory after implementation, followed by the Apple Silicon/Intel base
  matrix.
- Recovery repetition, battery, combined Host/Viewer budgets, Instruments, and
  the rest of section 15.2 remain open.
- No App or Agent was installed, launched, registered, or deployed. Hermes,
  CI, dependencies, database, TCC, real configuration, and secrets were not
  touched; nothing was pushed.
