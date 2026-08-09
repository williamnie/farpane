# H5.1b sleep/wake recovery order owner

## Outcome

A package-internal, toolkit-independent recovery owner now freezes the process-lifetime order required around system sleep and wake. It does not observe AppKit notifications itself and does not yet call the product media runtime.

Sleep preparation claims a new monotonic epoch, then performs: withdraw outward availability, publish suspending state, pause/flush media, and release the user-idle sleep assertion. Wake is admitted only after the matching sleep preparation completed, then performs: re-enumerate displays, revalidate permissions, rebuild media, resume registration, and publish availability.

## Failure and concurrency boundary

- Sleep preparation is cleanup. If an earlier operation fails, later pause/flush and assertion-release operations are still attempted in order; the first failed step becomes the terminal sanitized state afterward.
- Wake is fail closed. Display, permission or media failure prevents registration and availability from being restored.
- Duplicate or out-of-order sleep/wake signals perform no operations. State is marked transitional before callbacks run, so reentrant wake cannot overtake sleep preparation.
- Cancellation during an external callback prevents all later operations and cannot be overwritten by the callback's return.
- Epoch exhaustion fails before invoking any operation. No counter wraps to an earlier lifecycle.

## Verification

- `HostAgentSleepWakeRecoveryOwnerTests`: 5 tests, 0 failures. Coverage includes exact two-way order, duplicate/late signal rejection, cleanup-after-failure, wake failure, reentrant cancellation and generation exhaustion.
- `swift test`: 727 tests, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- Swift arm64 Release build succeeded.
- `git diff --check` passed.

## Remaining boundary

- This owner intentionally has no `AppKit`/`NSWorkspace` dependency and is not instantiated by the product process yet. Automated tests do not claim that a real Mac sleep notification was observed.
- `HostAgentMediaPipelineOwner.cancelAndWait()` is terminal. H5.1c must first add a resumable, epoch-bound media pause/flush seam before a product notification adapter can safely invoke this owner.
- Product callbacks must still bind XPC availability withdrawal, a sanitized suspended projection, sleep-assertion release, display enumeration, TCC revalidation, media reconstruction and Rendezvous recovery to the exact operations above.
- No App/Agent was launched, installed, registered or deployed; no product configuration or secret was read, nothing was pushed, and Hermes/CI/dependencies/databases were untouched.
