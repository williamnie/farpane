# H5.1o-b4 network recovery process composition

## Outcome

The exact-generation Host ABI v9 network recovery operation now travels through
the same running ownership chain as snapshots and sleep recovery:
`HostAgentCoreRuntime`, `HostAgentOwnedCoreRuntime`,
`HostAgentProcessRuntime`, and `HostAgentProcessLifetime`. The product process
also owns one composition that hard-binds the normalized path trigger to the
five-second authoritative convergence poller and the same Host lifetime.

This step deliberately contains no system network ingress. Constructing the
composition proves ownership, operation routing, convergence, failure, and
teardown behavior without claiming that a real path change is observed.

## Key evidence

- `HostAgentCoreControlSurface` exposes the typed generation operation and
  `HostControlClient` is its concrete product implementation. Every ownership
  layer forwards the exact `UInt64` while holding its existing running-state
  lock or lifetime gate; after stop/termination the call fails as `notRunning`
  and never reaches Core.
- `HostAgentNetworkPathRecoveryComposition` constructs
  `HostAgentNetworkPathRecoveryPollingOwner.makeProduct` with the pinned Host
  identity. Its recovery closure calls `lifetime.recoverNetworkPath`, while its
  observation closure copies the authoritative snapshot from that same
  lifetime.
- The composition constructs `HostAgentNetworkPathRecoveryTriggerOwner` and
  passes each accepted exact path generation directly to the poller. It does
  not expose injectable product recovery or observation closures that could
  bypass the real runtime.
- A converged result asks the serialized snapshot coordinator for a fresh
  projection. ABI rejection, timeout, contradictory authoritative state, or a
  rejected trigger requests sanitized `.error` process termination on a
  separate utility task, avoiding teardown from inside a polling completion.
- Teardown first stops and drains trigger admission, then cancels and drains
  the restart/snapshot/completion poller. The lifetime invalidates XPC identity
  before product preparation; that preparation cancels this owner before
  sleep, media, and snapshot resources, and only then does runtime/Core stop
  proceed.
- The process installs the composition after Host identity, media, and sleep
  recovery are established, and before periodic snapshot polling and XPC
  listener activation. Installation failure follows the existing terminal
  startup path.
- Product source still imports no `Network` framework and constructs no
  `NWPathMonitor`; no synthetic path sample is fed at startup.

## Verification

- `swift test --filter HostAgentCoreRuntimeTests`: 10 tests, 0 failures.
- `swift test --filter HostAgentOwnedCoreRuntimeTests`: 9 tests, 0 failures.
- `swift test --filter HostAgentNetworkPathRecoveryCompositionContractTests`:
  5 tests, 0 failures.
- `swift test --filter HostAgentNetworkPathRecoveryPollingOwnerTests`:
  9 tests, 0 failures.
- `swift test --filter HostAgentNetworkPathRecoveryTriggerOwnerTests`:
  9 tests, 0 failures.
- Network restart ABI and path recovery audits report schema 4 with no missing
  evidence.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`:
  812 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  26 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Root `git diff --check`: passed.

## Remaining boundary

There is no `NWPathMonitor` product adapter, observer queue, normalized initial
sample, or monitor teardown yet. Consequently real Wi-Fi/Ethernet/VPN changes,
active-session survival, and Mini/MBP behavior remain unverified. No App or
Agent was installed, launched, registered, deployed, or pushed. Host ABI,
snapshot/wire schema, Rust, Hermes, CI, dependencies, databases, real network
configuration, TCC/configuration, and secrets were untouched.
