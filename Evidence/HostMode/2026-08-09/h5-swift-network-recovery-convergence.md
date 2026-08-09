# H5.1o-b3 Swift network recovery convergence

## Outcome

The Swift Host client now exposes the Host ABI v9 network-path recovery
operation with stable semantic error classification. A separate process-ownable
polling owner baselines the authoritative Host snapshot, invokes the exact path
generation once, and waits for the same Host and sleep epoch to converge to
`running + ready/ready` within an exact five-second product window.

This layer is intentionally not yet constructed by `HostAgentProcess` and does
not observe the system network. It proves the typed operation and convergence
boundary without claiming real Wi-Fi, Ethernet, or VPN recovery.

## Key evidence

- `HostControlClient.recoverNetworkPath(generation:)` rejects zero locally,
  holds the existing Host lock, calls the dynamic shim once, and maps stable
  Host errors to stale generation, invalid state, unsupported, internal, or
  unknown failure. A successful return means accepted/pending only.
- Before calling the ABI, the polling owner copies a coherent authoritative
  baseline and pins both `hostInstanceId` and the current sleep
  `recoveryEpoch`. A concurrent sleep/wake lifecycle or replacement Host cannot
  impersonate network-recovery success.
- Only the exact next nonzero product path generation can start. The ABI
  operation is invoked exactly once, then snapshots are polled every 50 ms for
  at most 100 observations and 5,000 ms of monotonic uptime.
- The only success tuple is the pinned Host and epoch with sleep recovery
  `running`, Host `ready`, and registration `ready`. `starting/pending` stays
  pending; foreign identity, epoch drift, sleep states, malformed tuples, or
  copy/decode failure fail closed. Temporary snapshot unavailability remains
  pending only inside the bounded window.
- Terminal cancellation cancels scheduled work, waits for accepted in-flight
  restart/observation/completion work, and suppresses late polling and
  completion.
- The built-core lifecycle exercises the typed Swift client against the real
  arm64 dylib, including zero, duplicate, and future-generation rejection plus
  two accepted restarts that preserve Host identity, local ID, and sleep epoch.

## Verification

- `swift test --filter HostAgentNetworkPathRecoveryPollingOwnerTests`:
  9 tests, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test --filter HostBridgeContractTests`:
  3 tests, 0 failures.
- `swift test --filter CoreBridgeContractTests.testNetworkPathRecoveryABIErrorsAreClassifiedSemantically`:
  1 test, 0 failures.
- Network restart ABI and network-path recovery contract audits report schema 3
  with no missing evidence.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`:
  805 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  26 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Root `git diff --check`: passed.

## Remaining boundary

The same-lifetime network-recovery operation is not yet propagated through the
Host Agent runtime ownership stack, and `HostAgentProcess` does not construct
the trigger and polling owners. Product source still contains no
`NWPathMonitor` adapter. Real network switching, active-session survival, and
Mini/MBP acceptance therefore remain unverified. No App or Agent was installed,
launched, registered, deployed, or pushed. Hermes, CI, dependencies, databases,
network configuration, TCC/configuration, and secrets were untouched.
