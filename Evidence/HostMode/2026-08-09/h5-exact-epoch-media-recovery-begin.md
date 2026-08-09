# H5.1f exact-epoch media recovery begin seam

## Outcome

The HostAgent media owner now exposes one package-internal post-wake entry point instead of three independently orderable resume, convergence-poll, and polling-start methods. The entry point binds the exact suspended sleep epoch to media ingress resume and H5.1e's bounded convergence polling window.

Before mutating recovery state it snapshots the recovery owner and requires both `suspended` status and exact epoch equality. It then resumes media ingress and starts polling for that same epoch in a fixed order. A failed precondition, failed resume, or rejected polling start returns false and remains fail closed.

## Completion boundary

- The completion carries the exact completed epoch so a future product coordinator can reject stale results.
- Only the polling owner's `converged` outcome is mapped to success.
- Timeout, unavailable, and route failure are sanitized to false; they cannot independently resume registration or publish availability.
- The former split methods are removed from the HostAgent media owner, preventing product code from resuming media and then forgetting, delaying, or binding the convergence gate to another epoch.
- Terminal cancellation remains ordered as polling cancellation before underlying media recovery cancellation.

## Verification

- `HostMediaPipelineRecoveryPollingOwnerTests`: 7 tests, 0 failures.
- `HostMediaPipelineRouteOwnerTests`: 18 tests, 0 failures.
- `CoreBridgeContractTests`: 37 tests, 1 conditional built-core test skipped, 0 failures. The source contract checks the exact epoch guard, fixed `epoch check -> resume -> polling start` order, success sanitization, and removal of all three split entry points.
- `swift test`: 740 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: rerun before commit.

## Remaining boundary

- H5.1b remains a toolkit-independent, package-shared synchronous recovery-order contract whose wake half treats `rebuildMedia` as complete before it resumes registration. This step deliberately does not change that shared state contract.
- H5.1g must introduce an explicit matching-epoch waiting state in the product recovery coordinator. Registration and availability may advance only after display/TCC checks and a successful completion from this begin seam for the same epoch.
- `NSWorkspace` sleep/wake notification registration, real display/TCC operations, Rendezvous withdrawal/resume, and Rust sleep-assertion ownership remain open.
- No App/Agent was launched, installed, registered, deployed, or pushed. Hermes, CI, dependencies, databases, Host ABI, wire/XPC schema, and shared Rust code were untouched.
