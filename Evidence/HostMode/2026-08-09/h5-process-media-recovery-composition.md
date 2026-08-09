# H5.1h process-owned media recovery composition

## Outcome

An executable-private HostAgent composition now owns the H5.1g sleep/wake state machine and hard-binds both media operations to one real `HostAgentMediaPipelineOwner`. Sleep preparation calls its resumable pause/flush seam. Wake recovery forwards the exact sleep epoch and completion to H5.1f's bounded convergence begin seam.

Media pause and media begin are intentionally absent from the injectable product-operations struct. A future process installer therefore cannot replace convergence with a placeholder success closure while still using this composition.

## Required product authorities

The composition has no product defaults. Construction requires explicit closures for all seven non-media operations:

- withdraw outward availability;
- publish suspending state;
- release the sleep assertion;
- re-enumerate displays;
- revalidate TCC permissions;
- resume Rendezvous registration;
- publish available state.

Snapshot, sleep, wake, and cancellation are forwarded only to the shared recovery owner. Composition deinitialization cancels that owner; terminal media teardown remains owned by the existing HostAgent process lifetime.

## Verification

- `HostAgentSleepWakeRecoveryCompositionContractTests`: 2 tests, 0 failures. The source contract proves hard binding to real media pause/begin, exact epoch/completion forwarding, absence of injectable media operations, all seven required non-media dependencies, and lifecycle/cancel forwarding.
- `HostAgentSleepWakeRecoveryOwnerTests`: 11 tests, 0 failures.
- `HostMediaPipelineRecoveryPollingOwnerTests`: 7 tests, 0 failures.
- `swift test`: 748 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: rerun before commit.

## Remaining boundary

- `HostAgentProcess` does not construct this composition yet. Installing it with invented always-success operations would violate the H5.1g fail-closed contract.
- H5.1i can implement the display/TCC authority from local macOS APIs without changing Host ABI. Its snapshot must represent one coherent post-wake observation and must not prompt from the background Agent.
- Registration withdrawal/resume and Rust sleep-assertion ownership have no current Host ABI operations. They require a separate versioned ABI and runtime-lifecycle checkpoint before process installation.
- `NSWorkspace` notification wiring and real sleep/wake acceptance remain later steps. No App/Agent was launched, installed, registered, deployed, or pushed; Hermes, CI, dependencies, databases, and secrets were untouched.
