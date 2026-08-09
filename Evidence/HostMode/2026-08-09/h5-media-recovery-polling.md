# H5.1e bounded media recovery polling owner

## Outcome

The HostAgent media owner now owns a package-internal polling owner for H5.1d's asynchronous fresh-route convergence gate. Each recovery starts with an exact, strictly increasing sleep epoch and gets its own terminal callback. Product defaults sample every 50 milliseconds, permit at most 100 samples, and enforce an independent five-second monotonic deadline based on `DispatchTime.uptimeNanoseconds`.

The deadline is not inferred only from attempt count. Before a delayed tick polls the route owner, it compares the current monotonic clock to the fixed deadline; a tick arriving after the deadline completes as timed out without touching recovery state. A pending result at the deadline or at attempt 100 also times out. This prevents a starved dispatch queue from silently extending the logical recovery window.

## Lifecycle and failure boundary

- `converged` completes the exact epoch successfully. `failed` and `unavailable` both fail closed; only `pending` schedules another sample.
- Completed owners accept only a strictly newer epoch. Duplicate and rollback epochs cannot reuse a prior completion or timer.
- The HostAgent in-process media snapshot now includes polling state, but no XPC/wire/schema field changes.
- Terminal HostAgent teardown cancels the recovery poller before stopping telemetry polling and the underlying media recovery owner. Cancellation invalidates scheduled work and waits for an in-flight poll or completion callback before returning.
- A cancelled owner is terminal. A late scheduled task cannot poll or deliver completion after cancellation.

## Verification

- `HostMediaPipelineRecoveryPollingOwnerTests`: 7 tests, 0 failures. Coverage includes exact product bounds, pending-to-success, start failure, attempt timeout, monotonic-deadline overrun without polling, strictly increasing epochs, scheduled cancellation, and cancellation while a poll is blocked.
- `CoreBridgeContractTests`: 37 tests, 1 conditional built-core test skipped, 0 failures. Product source contract confirms construction, start/snapshot seams, and cancellation before the underlying media owner.
- `swift test`: 740 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: passed before evidence finalization and is rerun before commit.

## Remaining boundary

- The polling owner is constructed with the HostAgent media owner, but H5.1b is still not composed into the product process and therefore does not start a recovery epoch yet.
- A terminal media polling result is not permission to resume registration by itself. The future product recovery composition must require the matching epoch, successful display/TCC revalidation, and successful registration recovery before publishing availability.
- `NSWorkspace` sleep/wake notification registration, Rendezvous withdrawal/resume, and explicit Rust sleep-assertion release remain open. The current Host ABI has no sleep-specific registration/assertion operation; this step does not add or simulate one.
- No App/Agent was launched, installed, registered or deployed; no real product configuration, media log, or secret was read; nothing was pushed, and Hermes/CI/dependencies/databases were untouched.
