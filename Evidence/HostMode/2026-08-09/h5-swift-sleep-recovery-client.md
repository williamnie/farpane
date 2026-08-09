# H5.1l-a Swift sleep/recovery client

## Outcome

`HostControlClient` now exposes the Host ABI v8 sleep boundary as three typed,
serialized calls:

1. `beginSleep(epoch:)` accepts a nonzero epoch and only means that Rust
   accepted registration withdrawal.
2. `finishSleep(epoch:)` synchronously waits for the matching registration
   join and Rust-owned assertion-drop acknowledgement.
3. `resumeAfterWake(epoch:)` only accepts restart. It never means the Host is
   ready; readiness still requires a later authoritative snapshot for the same
   epoch with recovery `running` and registration `ready`.

The client holds its existing Host lock across each ABI call, so terminal stop,
snapshot access, and recovery mutation cannot concurrently use or destroy the
same opaque Host handle. Epoch zero fails before crossing C. Missing Host,
stale/future epoch, unsupported surface, internal failure, and unknown errors
remain distinct typed failures instead of being collapsed into success or a
generic media/stop error.

## Built-core evidence

The existing isolated full Host lifecycle now creates a real
`HostControlClient` against the arm64 dylib and executes:

`start → reject epoch 0 → begin(1) → reject finish(2) → finish(1) → reject
resume(2) → resume(1) → snapshot → terminal stop`.

Snapshots proved `suspending`, then `suspended`, followed by either the
asynchronous `resuming/pending` state or an already converged `running/ready`
state. The test does not infer readiness from the `resumeAfterWake` return.

## Verification

- `swift test --filter CoreBridgeContractTests/testSleepRecoveryABIErrorsAreClassifiedSemantically`: 1 test, 0 failures.
- `python3 -m unittest Tests.ScriptTests.test_host_sleep_recovery_contract_audit`: 1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test --filter HostBridgeContractTests`: 3 tests, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`: 759 tests, 0 skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `python3 Scripts/audit-host-sleep-recovery-contract.py`: schema 3,
  `contract-implemented`, no missing evidence; only synchronous product
  composition remains open.

## Remaining boundary

H5.1l is not complete. H5.1l-b must replace the executable composition's
synchronous registration/availability closures with exact-epoch snapshot
convergence. It must call these client operations in the frozen order and may
publish available only after the same epoch is authoritative
`running + registration ready`.

No `HostAgentProcess` or `NSWorkspace` notification was wired in this step. No
App/Agent was launched, installed, registered, deployed, or pushed. Hermes,
CI, dependencies, databases, real TCC/configuration, and secrets were untouched.
