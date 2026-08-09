# H5.1m-b process-owned exact-epoch recovery composition

## Outcome

The executable HostAgent now constructs and retains the complete sleep/wake
recovery composition before snapshot polling and the XPC listener become
active. Termination cancels recovery first, followed by media ingress, the
media pipeline, and snapshot polling.

Recovery projection uses the existing `HostAgentSnapshotRefreshCoordinator`
instead of a second snapshot writer. It waits for an in-flight event or poll
copy, copies from the same lifetime, and publishes only a pinned Host with the
exact epoch and requested recovery/registration tuple. It then drains ordinary
refresh work that arrived during the recovery copy. Contradictory state, copy
failure, host mismatch, cancellation, and stale publication all fail closed.

The process owner hard-binds the product display/TCC authority. Suspending
publication requires exact `suspending/suspending`; final availability requires
exact `running/ready`. The composition captures its lifetime weakly, while the
lifetime termination preparation retains the process owner, avoiding a retain
cycle without allowing the owner to disappear before teardown.

## Key evidence

- Snapshot authority behavior tests prove exact suspending and running
  publication, contradiction invalidation, and waiting behind an in-flight
  refresh.
- Product source contracts prove recovery installation occurs after the media
  pipeline and before snapshot polling/XPC listener activation.
- Teardown source contracts prove recovery cancellation precedes media ingress,
  media pipeline, and snapshot polling cancellation.
- The machine audit is schema 6, has no missing evidence, and reports only the
  absent system sleep/wake notification adapter as the remaining boundary.

## Verification

- `swift test --filter 'HostAgentSleepWakeRecoveryProcessOwnerContractTests|HostAgentSnapshotStateTests|HostAgentSleepWakeRecoveryCompositionContractTests'`: 23 tests, 0 failures.
- `python3 -m unittest Tests.ScriptTests.test_host_sleep_recovery_contract_audit`: 1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`: 777 tests, 0 skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `python3 Scripts/audit-host-sleep-recovery-contract.py`: schema 6,
  `contract-implemented`, no missing evidence; only
  `systemSleepWakeNotificationAdapterAbsent` remains true.
- `git diff --check`: passed.

## Remaining boundary

No `NSWorkspace`/AppKit sleep or wake notification ingress was registered, so
no real Mac sleep lifecycle is claimed. No App or Agent was launched,
installed, registered, deployed, or pushed. The Host ABI, Rust, wire schema,
Hermes, CI, dependencies, databases, real TCC/configuration, and secrets were
untouched.
