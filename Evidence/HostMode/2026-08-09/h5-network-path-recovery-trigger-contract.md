# H5.1o-a network-path recovery trigger contract

## Outcome

A package-internal owner now normalizes network observations into exact Host
recovery triggers without coupling path observation to sleep recovery state.
The first usable path establishes a baseline and does not restart HostCore.
After that baseline, an observed outage followed by any usable path, or a
material change to the usable path identity, produces one strictly monotonic
path generation and invokes one required trigger operation.

Usable paths require `satisfied`, at least one non-loopback interface, and an
IPv4 or IPv6 family. Material identity includes interface kinds, address-family
support, and DNS support. Expensive/constrained policy changes remain recorded
in the latest snapshot but do not restart registration by themselves. The path
generation is deliberately separate from the Host sleep `recoveryEpoch` and
from media connection/codec/display epochs.

Trigger rejection, malformed satisfied paths, generation exhaustion,
concurrent samples, and post-cancellation work fail closed. Terminal
cancellation closes admission and waits for an accepted synchronous trigger;
its late success cannot overwrite cancelled state.

## Key evidence

- Nine behavior tests cover initial online/offline baselines, repeated outage,
  same-path recovery, Wi-Fi/Ethernet and address-family changes, policy-only
  changes, malformed and loopback-only paths, trigger rejection, generation
  exhaustion, concurrency, and cancellation drain.
- The schema-1 machine audit reports every trigger-contract invariant present
  and keeps both product integration boundaries explicit.
- No `NWPathMonitor` product adapter or HostCore network-recovery operation is
  synthesized by this step.

## Verification

- `swift test --filter HostAgentNetworkPathRecoveryTriggerOwnerTests`: 9 tests,
  0 failures.
- `python3 -m unittest Tests.ScriptTests.test_host_network_path_recovery_contract_audit`:
  1 test, 0 failures.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`:
  795 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 25 tests,
  0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `python3 Scripts/audit-host-network-path-recovery-contract.py`: schema 1,
  `trigger-contract-implemented`, no missing evidence; both remaining product
  boundaries are true.
- `git diff --check`: passed.

## Remaining boundary

The owner is not constructed by HostAgent, no `Network.NWPathMonitor` is
started, and HostCore has no command/ABI operation that restarts Rendezvous and
Relay recovery for a path generation. Therefore this step does not claim a
real Wi-Fi/Ethernet/VPN switch or session recovery. No App or Agent was
launched, installed, registered, deployed, or pushed. Sleep recovery ABI,
snapshot/wire schemas, Rust, Hermes, CI, dependencies, databases, real network
configuration, TCC/configuration, and secrets were untouched.
