# H5.1m-a same-lifetime exact-epoch sleep ABI binding

## Outcome

The sleep/recovery ABI now stays on the same process-owned HostCore lifetime.
`beginSleep(epoch:)`, `finishSleep(epoch:)`, and `resumeAfterWake(epoch:)` are
required by `HostAgentCoreControlSurface` and forwarded without changing the
epoch through `HostAgentCoreRuntime`, `HostAgentOwnedCoreRuntime`,
`HostAgentProcessRuntime`, and `HostAgentProcessLifetime`. Every layer rejects
access after its terminal stop boundary.

The shared recovery operations now carry the exact epoch for availability
withdrawal, suspending publication, assertion release, and available
publication. The executable composition hard-binds withdrawal to
`lifetime.beginSleep(epoch:)`, assertion release to
`lifetime.finishSleep(epoch:)`, and internally constructs registration
convergence from `lifetime.resumeAfterWake(epoch:)` plus
`lifetime.copySnapshot()`. Callers can no longer inject placeholder sleep,
resume, or snapshot operations.

## Key evidence

- Runtime behavior tests prove all three operations preserve epochs 7 and 9
  through the direct and owned runtime layers, then fail with `notRunning`
  after stop without reaching the control surface again.
- Recovery-owner tests prove the same epoch reaches withdrawal, suspending,
  assertion release, and final availability publication.
- Composition source contracts prove media, begin/finish, registration resume,
  and snapshot observation are hard-bound; only exact-epoch suspending and
  available projection publication remain explicit product operations.
- The machine audit is schema 5, has no missing evidence, and reports only
  process projection binding and process composition construction as remaining.

## Verification

- `swift test --filter 'HostAgentSleepWakeRecoveryOwnerTests|HostAgentSleepWakeRecoveryCompositionContractTests|HostAgentCoreRuntimeTests|HostAgentOwnedCoreRuntimeTests'`: 32 tests, 0 failures.
- `python3 -m unittest Tests.ScriptTests.test_host_sleep_recovery_contract_audit`: 1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`: 770 tests, 0 skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `python3 Scripts/audit-host-sleep-recovery-contract.py`: schema 5,
  `contract-implemented`, no missing evidence; only
  `processProjectionOperationsUnbound` and
  `processSleepWakeCompositionAbsent` remain true.
- `git diff --check`: passed.

Historical note: this H5.1m-a result was committed as `09de6a7`. H5.1m-b
later advanced the machine audit to schema 6 by binding exact-epoch projection
and constructing the recovery composition in `HostAgentProcess`; the schema-5
result above remains the fresh verification recorded for this earlier boundary.

## Remaining boundary

This step does not construct the recovery composition in `HostAgentProcess`,
bind its projection operations to the snapshot authority, or register
`NSWorkspace` notifications. No App or Agent was launched, installed,
registered, deployed, or pushed. The Host ABI, Rust, wire schema, Hermes, CI,
dependencies, databases, real TCC/configuration, and secrets were untouched.
