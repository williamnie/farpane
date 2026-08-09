# H5.1g exact-epoch asynchronous wake waiting contract

## Outcome

The package-shared, toolkit-independent sleep/wake owner no longer treats media rebuild as a synchronous boolean immediately followed by registration resume. Its wake path now performs display re-enumeration and permission revalidation, begins recovery with the current sleep epoch, and remains in `waitingForMedia(epoch)` until a completion for that exact epoch succeeds.

Only then does the owner enter `restoringRegistration(epoch)`, resume registration, publish availability, and return to `running(epoch)`. The state transition is observable through the existing package-internal snapshot but does not add any Host ABI or XPC/wire field.

## Fail-closed and reentrancy boundary

- A rejected media begin terminates at `failed(epoch, .rebuildMedia)` without resuming registration or publishing availability.
- A matching failed completion terminates at the same step. A later success cannot revive it.
- Old, future, and duplicate epoch completions are ignored; registration and availability run at most once for the accepted epoch.
- The owner marks `waitingForMedia` before calling the adapter, so reentrant wake/sleep notifications cannot claim the transition.
- A completion delivered synchronously from inside the begin closure is buffered until begin returns. If begin ultimately returns false, even a buffered success is discarded and the owner fails closed.
- Cancellation clears the in-flight epoch and buffered completion. Synchronous or late completion after cancellation cannot restore registration or availability.
- A matching media success only opens the registration phase. If registration resume fails, publishing availability is not attempted.

## Verification

- `HostAgentSleepWakeRecoveryOwnerTests`: 11 tests, 0 failures. Coverage includes exact asynchronous ordering, wrong epoch, duplicate completion, preflight failure, begin rejection, failed completion, post-media registration failure, synchronous accepted/rejected completion, cancellation during begin, sleep-transition reentrancy, and epoch exhaustion.
- `swift test`: 746 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: rerun before commit.

## Remaining boundary

- The shared state contract is executable and tested, but the HostAgent process still does not construct this owner or bind H5.1f's real media begin seam to its completion.
- H5.1h must add process-owned composition while preserving the exact epoch through display/TCC, media, registration, availability, and sleep-assertion operations. A media success alone is not a substitute for the later operation results.
- `NSWorkspace` sleep/wake notification registration, real display/TCC revalidation, Rendezvous withdrawal/resume, and Rust sleep-assertion ownership remain open.
- No App/Agent was launched, installed, registered, deployed, or pushed. Hermes, CI, dependencies, databases, Host ABI, wire/XPC schema, Rust, and real product storage were untouched.
