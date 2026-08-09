# H5.1n process-owned system sleep/wake notification ingress

## Outcome

HostAgent now owns an AppKit power-notification adapter for
`NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`.
The adapter registers on a dedicated kept-alive RunLoop, so the command-line
HostAgent does not depend on `NSApplication` or the main event loop to retain
the observation boundary.

A toolkit-independent delivery owner admits only exact
`awake → willSleep → sleeping → didWake → awake` cycles. Duplicate,
out-of-order, concurrent, failed, and post-cancellation events fail closed.
Terminal teardown removes both observers, closes delivery admission, waits for
the accepted callback already in flight, and only then stops the observer
RunLoop and cancels the recovery composition.

The recovery process owner starts this ingress with its exact-lifetime
composition before snapshot polling and XPC listener activation. An unexpected
observer RunLoop exit asynchronously requests process termination rather than
leaving a running HostAgent that silently misses future recovery events.
An accepted sleep or wake edge whose recovery operation fails uses the same
terminal path; rejected duplicates do not request termination.

## Key evidence

- Six behavior tests cover exact cycles, duplicate/out-of-order rejection,
  fail-closed operation failures, concurrent delivery, and cancellation drain.
- Three product source contracts pin whole-system power notifications, the
  dedicated RunLoop, observer-removal/drain order, and process ownership.
- The schema-7 machine audit reports the system ingress implemented with no
  missing source evidence.
- The remaining boundary is explicitly real-Mac sleep/wake lifecycle evidence;
  screen sleep notifications are intentionally not used as a substitute.

## Verification

- `swift test --filter 'HostAgent(NSWorkspaceSleepWakeIngressContract|SleepWakeRecoveryProcessOwnerContract|SleepWakeNotificationDeliveryOwner)Tests'`: 12 tests, 0 failures.
- `python3 -m unittest Tests.ScriptTests.test_host_sleep_recovery_contract_audit`: 1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`: 786 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 24 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `python3 Scripts/audit-host-sleep-recovery-contract.py`: schema 7,
  `contract-implemented`, no missing evidence;
  `realMacSleepWakeLifecycleEvidenceRequired=true`.
- `git diff --check`: passed.

## Remaining boundary

No real Mac was put to sleep or woken during this step, and no installed
HostAgent/App lifecycle was exercised. This evidence therefore does not claim
that registration, media, display/TCC, assertion, or remote-session recovery
has passed on hardware. No App or Agent was launched, installed, registered,
deployed, or pushed. Host ABI/Rust/wire schema, Hermes, CI, dependencies,
databases, real TCC/configuration, and secrets were untouched.
