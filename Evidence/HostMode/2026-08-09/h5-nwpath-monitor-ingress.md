# H5.1o-b5 process-owned NWPathMonitor ingress

## Outcome

The running HostAgent network recovery owner now constructs and starts one
`NWPathMonitor` on a dedicated serial utility queue. The monitor's own first
callback establishes the existing trigger baseline; product code does not read
`currentPath` or synthesize a startup path. Every callback is strictly mapped
to `HostAgentNetworkPathSnapshot` and delivered through a process-owned,
fail-closed admission/drain owner before reaching the trigger and bounded
HostCore recovery composition.

This closes the automatic product wiring for network-path recovery. It does not
claim a real Wi-Fi, Ethernet, or VPN switch has been accepted on Mini/MBP.

## Key evidence

- `NWPath.Status.satisfied`, `requiresConnection`, and `unsatisfied` map to the
  three typed availability values; an unknown future status maps to
  `unsatisfied`.
- Only interfaces for which `path.usesInterfaceType(interface.type)` is true
  are retained. Known `other`, Wi-Fi, cellular, wired Ethernet, and loopback
  types map exactly; a future type conservatively maps to `other`.
- IPv4, IPv6, DNS, expensive, and constrained flags are copied directly. The
  existing trigger remains the single authority that decides whether a sample
  is usable, unchanged, policy-only, or requires exact-generation recovery.
- `HostAgentNetworkPathDeliveryOwner` admits one normalized sample at a time.
  Operation rejection becomes terminal failed; cancellation closes admission,
  drains the one accepted delivery, and reports late work as closed rather than
  as a new product failure.
- The monitor handler is installed before `start(queue:)`. Rejected active
  delivery requests sanitized process termination on a separate utility task;
  closed post-cancel delivery is silent.
- Process teardown first clears the handler and cancels the monitor, then drains
  normalized delivery, and only afterward drains trigger/restart/snapshot
  convergence. Startup cancellation uses the same order.
- A local read-only smoke received the monitor's first callback within the
  three-second bound without logging path details.

## Verification

- `swift test --filter HostAgentNetworkPathDeliveryOwnerTests`: 5 tests,
  0 failures.
- `swift test --filter HostAgentNWPathMonitorIngressContractTests`: 4 tests,
  0 failures.
- `swift test --filter HostAgentNetworkPathRecoveryCompositionContractTests`:
  4 tests, 0 failures.
- Existing trigger and convergence owner suites: 9 + 9 tests, 0 failures.
- Local `NWPathMonitor` first-callback smoke: `initial-callback-ok` within
  3 seconds; no status, interface, endpoint, address, or network identifier was
  printed.
- Network restart ABI and path recovery audits report schema 5 with no missing
  evidence.
- `RDN_CORE_LIBRARY="$PWD/Build/CoreBridge/arm64/liblibrustdesk.dylib" swift test`:
  820 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`:
  26 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- Root `git diff --check`: passed.

## Remaining boundary

No interface was toggled and no VPN was started or stopped. Real direct/relay
behavior, active-session survival, readiness convergence on the Mac mini, and
interaction with a simultaneous sleep/wake edge remain unverified. Those need
an installed build and user-controlled Mini/MBP network changes. No App or
Agent was installed, launched, registered, deployed, or pushed. Host ABI,
snapshot/wire schema, Rust, Hermes, CI, dependencies, databases, network
configuration, TCC/configuration, and secrets were untouched.
