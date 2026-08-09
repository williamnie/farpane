# H5.1o-b1 HostCore network restart ABI ownership audit

## Outcome

The existing HostCore ownership is sufficient for an identity-preserving
registration restart, but no public operation exposes it yet. `HostRuntime`
owns the Rendezvous mediator thread, its stop signal, join, online-state reset,
and restart using the Host's pinned rendezvous server. The public Host stop
operation is terminal: it also unbinds media/session authority and rotates the
temporary password. The sleep operations separately own `recoveryEpoch` and
the Rust wakelock state. Neither path can safely stand in for network recovery.

The next contract is frozen as Host ABI version 9 with snapshot schema version
6. This audit deliberately does not implement or advertise that ABI.

## Frozen ABI v9 target

1. Add `rdn_host_recover_network_path(host, path_generation)` and a distinct
   `RDN_HOST_ERR_STALE_GENERATION`. The Host stores a separate
   `network_path_generation`; it never reuses sleep, connection, codec, or
   display epochs.
2. Admission requires the exact next nonzero generation, Host `starting` or
   `ready`, sleep recovery `running`, and a live registration runtime. Validate
   every premise before the first side effect.
3. A successful call is synchronous restart admission, not readiness. It
   commits the generation, publishes `starting/pending`, stops and joins the
   old registration runtime (thereby clearing old online state), and starts a
   new runtime with the same in-memory rendezvous server. It returns only after
   that sequence, so a subsequent `ready` snapshot cannot be the pre-restart
   online state.
4. Swift readiness must use bounded authoritative snapshot polling and require
   the pinned `hostInstanceID`, sleep recovery `running`, and registration
   `ready`. No snapshot schema expansion is needed because the synchronous ABI
   boundary has already retired the old runtime and online state before return.
5. Runtime join/start failures are terminal and fail closed as Host `error`,
   registration `degraded`, sleep recovery still `running`, and a sanitized
   network-recovery diagnostic. The same failed Host cannot silently retry.
6. The operation must not mutate identity or persisted registration config,
   bind/unbind media or sessions, rotate either password class, touch sleep
   recovery/wakelock state, or alter connection/codec/display epochs.

## Key evidence

- The schema-1 machine audit pins Host ABI v8 and snapshot schema v6 as the
  current baseline and checks the target symbol is absent from Rust, header,
  shim, and build symbol gate.
- `HostRuntime::start/request_stop/join` contains the bounded registration
  primitives and no media, password, or wakelock side effects.
- `RdnHost` retains `instance_id`, stable `local_id`, registration endpoints,
  public key, and the runtime handle in one Host lifetime.
- The current Swift snapshot decoder can represent `running` with
  `starting/pending`, `ready/ready`, or terminal `error/degraded`; no new wire
  field is required for this internal path-generation operation.
- H5.1o-a already owns an independent exact-monotonic path generation and will
  be the only caller after the ABI and convergence layers exist.

## Verification

- `python3 Scripts/audit-host-network-restart-abi-contract.py`: schema 1,
  `contract-frozen`, no missing evidence.
- `python3 -m unittest Tests.ScriptTests.test_host_network_restart_abi_contract_audit`:
  1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`:
  795 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  26 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: passed.

## Remaining boundary

H5.1o-b2 must implement Host ABI v9 across the Rust bridge, C header, dynamic
shim, built-core symbol gate, and lifecycle tests. A later bounded step must add
the typed Swift call plus ready convergence before constructing the
`NWPathMonitor` product adapter. No real network switch, active-session
survival, sleep/wake, Mini/MBP, installation, launch, registration, deployment,
or push is claimed here. Hermes, CI, dependencies, databases, real network
configuration, TCC/configuration, and secrets were untouched.
