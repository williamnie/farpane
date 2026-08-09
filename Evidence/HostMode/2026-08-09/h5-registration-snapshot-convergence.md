# H5.1l-b exact-epoch registration snapshot convergence

## Outcome

Wake recovery no longer treats registration resume as synchronous readiness.
The executable-private composition now owns a bounded registration recovery
poller and the shared recovery owner waits in `waitingForRegistration(epoch:)`
after media recovery succeeds. Availability is published only after the poller
observes a direct authoritative HostCore snapshot for the pinned Host with the
same recovery epoch, recovery `running`, and registration `ready`.

The poller calls the injected resume operation exactly once. An accepted return
only begins polling at the product bounds of 50 ms, 100 attempts, and a 5-second
monotonic deadline. A stale epoch, temporarily unavailable snapshot, or the
matching `resuming/pending` state remains pending only inside that window.
Foreign Host identity, a future epoch, failed/suspending/suspended or otherwise
incompatible state, timeout, resume rejection, and cancellation fail closed.

Matching success is also required at the recovery-owner completion boundary.
Old, future, duplicate, or failed registration completions cannot restore
availability. A completion delivered synchronously from begin is buffered until
begin returns accepted, so a later rejection cannot be bypassed by reentrancy.
Terminal composition cancellation drains registration recovery work before the
display/TCC authority is cancelled.

## Key evidence

- `HostAgentRegistrationRecoveryPollingOwner` pins `expectedHostInstanceID`,
  exact recovery epoch, and the `running + ready` snapshot predicate.
- `HostAgentSleepWakeRecoveryOwner` exposes a distinct
  `waitingForRegistration(epoch:)` state and publishes available only after a
  matching successful completion.
- `HostAgentSleepWakeRecoveryComposition` hard-binds its registration begin
  seam to the owned poller; callers cannot supply an immediate-success resume
  closure.
- The machine audit is schema 4, reports all 14 evidence predicates true and
  no missing evidence. Its only remaining boundaries are sleep-preparation ABI
  binding and process sleep/wake composition.

## Verification

- `swift test --filter 'HostAgentSleepWakeRecoveryCompositionContractTests|HostAgentDisplayTCCRecoveryAuthorityContractTests|HostAgentSleepWakeRecoveryOwnerTests|HostAgentRegistrationRecoveryPollingOwnerTests'`: 23 tests, 0 failures.
- `python3 -m unittest Tests.ScriptTests.test_host_sleep_recovery_contract_audit`: 1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`: 767 tests, 0 skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `python3 Scripts/audit-host-sleep-recovery-contract.py`: schema 4,
  `contract-implemented`, no missing evidence; only
  `sleepPreparationABIOperationsStillUnbound` and
  `processSleepWakeCompositionAbsent` remain true.
- `git diff --check`: passed.

## Remaining boundary

This step does not construct the composition in `HostAgentProcess`, register
`NSWorkspace` notifications, or bind sleep preparation to the Host ABI
begin/finish operations. No App or Agent was launched, installed, registered,
deployed, or pushed. Hermes, CI, dependencies, databases, real TCC/configuration,
and secrets were untouched.
