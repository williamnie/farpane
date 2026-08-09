# H5.1i coherent display/TCC wake revalidation

## Outcome

A package-level recovery owner now produces one coherent, revisioned post-wake display/TCC snapshot. The executable product authority supplies real local macOS observations, and H5.1h's composition hard-binds both display and permission operations to that authority instead of accepting caller-provided closures.

Each attempt performs:

1. enumerate and normalize active displays;
2. observe TCC without prompting;
3. enumerate and normalize active displays again;
4. publish ready only when both inventories are identical.

Successful attempts increment a monotonic revision. A later wake may begin from the prior ready revision. Failure and cancellation remain terminal for the current owner.

## Display and permission boundary

- Displays use canonical `CGDirectDisplayID`, non-zero pixel dimensions, finite global origin and rotation, exactly one main display, unique IDs, and canonical ID ordering. Empty, malformed, duplicated, or headless inventories fail as unavailable.
- A display add/remove, dimension, layout, rotation, main-display, or identity change between the two observations fails as `displayChangedDuringValidation`.
- Screen Recording and Accessibility are required for controlled-side capture and event injection. Either denial fails before a second display observation.
- Input Monitoring is observed and retained in the snapshot but does not gate controlled-side recovery; it is needed for global event listening, not for posting already-authorized remote input.
- Product observation uses `CGPreflightScreenCaptureAccess`, `AXIsProcessTrustedWithOptions` with prompt explicitly false, and `CGPreflightListenEventAccess`. It never calls request APIs, `NSAlert`, or `NSWorkspace`.

## Composition and cancellation

- Display re-enumeration and TCC revalidation are no longer fields in `HostAgentSleepWakeRecoveryProductOperations`.
- The composition forwards both operations to one `HostAgentDisplayTCCRecoveryAuthority` and exposes its typed snapshot for future diagnostics.
- Terminal composition cancellation seals the shared sleep/wake owner first, then cancels the display/TCC authority so an in-flight observation cannot advance recovery afterward.
- The five remaining explicit product authorities are availability withdrawal/suspending publication, assertion release, registration resume, and available publication.

## Verification

- `HostAgentDisplayTCCRecoveryOwnerTests`: 8 tests, 0 failures. Coverage includes normalized stable inventory, revision advance, optional Input Monitoring, both required TCC failures, display membership and layout changes, malformed inventories, reentrant cancellation, invalid order, and generation exhaustion.
- `HostAgentDisplayTCCRecoveryAuthorityContractTests`: 2 tests, 0 failures. The source contract proves non-prompting product APIs and hard composition binding/cancellation order.
- `HostAgentSleepWakeRecoveryCompositionContractTests`: 2 tests, 0 failures.
- `swift test`: 758 tests, 4 conditional skips, 0 failures.
- `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`: 23 tests, 0 failures.
- `swift build -c release --arch arm64`: succeeded.
- `git diff --check`: rerun before commit.

## Remaining boundary

- The authority has not queried the user's real TCC database or been driven by a real sleep/wake notification. Those are later GUI/device acceptance boundaries.
- `HostAgentProcess` still does not construct the recovery composition. Registration withdrawal/resume and sleep-assertion ownership have no current Host ABI operations; fake successes remain forbidden.
- H5.1j must audit the pinned Rust runtime's Rendezvous and power-assertion lifecycle, then define the minimum versioned Host ABI behavior before process installation.
- No App/Agent was launched, installed, registered, deployed, or pushed. Hermes, CI, dependencies, databases, secrets, and real product storage were untouched.
