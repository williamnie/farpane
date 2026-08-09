import Foundation

package enum HostAgentSleepWakeRecoveryStep: String, Equatable, Sendable {
    case generationExhausted
    case withdrawAvailability
    case publishSuspending
    case pauseMediaAndFlush
    case releaseSleepAssertion
    case reenumerateDisplays
    case revalidatePermissions
    case rebuildMedia
    case resumeRegistration
    case publishAvailable
}

package enum HostAgentSleepWakeRecoveryState: Equatable, Sendable {
    case running(epoch: UInt64)
    case preparingForSleep(epoch: UInt64)
    case sleeping(epoch: UInt64)
    case recovering(epoch: UInt64)
    case failed(epoch: UInt64, step: HostAgentSleepWakeRecoveryStep)
    case cancelled
}

/// Synchronous operations owned by the future product adapter. Every closure
/// returns false on a fail-closed boundary and must not expose implementation
/// errors, TCC details, display names, connection IDs or frame contents.
package struct HostAgentSleepWakeRecoveryOperations: Sendable {
    package let withdrawAvailability: @Sendable () -> Bool
    package let publishSuspending: @Sendable () -> Bool
    package let pauseMediaAndFlush: @Sendable () -> Bool
    package let releaseSleepAssertion: @Sendable () -> Bool
    package let reenumerateDisplays: @Sendable () -> Bool
    package let revalidatePermissions: @Sendable () -> Bool
    package let rebuildMedia: @Sendable () -> Bool
    package let resumeRegistration: @Sendable () -> Bool
    package let publishAvailable: @Sendable () -> Bool

    package init(
        withdrawAvailability: @escaping @Sendable () -> Bool,
        publishSuspending: @escaping @Sendable () -> Bool,
        pauseMediaAndFlush: @escaping @Sendable () -> Bool,
        releaseSleepAssertion: @escaping @Sendable () -> Bool,
        reenumerateDisplays: @escaping @Sendable () -> Bool,
        revalidatePermissions: @escaping @Sendable () -> Bool,
        rebuildMedia: @escaping @Sendable () -> Bool,
        resumeRegistration: @escaping @Sendable () -> Bool,
        publishAvailable: @escaping @Sendable () -> Bool
    ) {
        self.withdrawAvailability = withdrawAvailability
        self.publishSuspending = publishSuspending
        self.pauseMediaAndFlush = pauseMediaAndFlush
        self.releaseSleepAssertion = releaseSleepAssertion
        self.reenumerateDisplays = reenumerateDisplays
        self.revalidatePermissions = revalidatePermissions
        self.rebuildMedia = rebuildMedia
        self.resumeRegistration = resumeRegistration
        self.publishAvailable = publishAvailable
    }
}

/// Serializes one process-lifetime sleep/wake recovery sequence without
/// importing AppKit or owning notification registration. Product callbacks
/// may be reentrant; the owner marks a transition before invoking any closure,
/// calls closures without holding its lock, and never resumes after a failed
/// or cancelled step.
package final class HostAgentSleepWakeRecoveryOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let operations: HostAgentSleepWakeRecoveryOperations
    private var state: HostAgentSleepWakeRecoveryState

    package init(
        initialEpoch: UInt64 = 0,
        operations: HostAgentSleepWakeRecoveryOperations
    ) {
        self.operations = operations
        self.state = .running(epoch: initialEpoch)
    }

    package func snapshot() -> HostAgentSleepWakeRecoveryState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Claims one running epoch. Duplicate, out-of-order or reentrant sleep
    /// notifications are rejected without invoking a second operation.
    @discardableResult
    package func systemWillSleep() -> Bool {
        lock.lock()
        guard case .running(let currentEpoch) = state else {
            lock.unlock()
            return false
        }
        guard currentEpoch < UInt64.max else {
            state = .failed(
                epoch: currentEpoch,
                step: .generationExhausted
            )
            lock.unlock()
            return false
        }
        let epoch = currentEpoch + 1
        let transition = HostAgentSleepWakeRecoveryState.preparingForSleep(
            epoch: epoch
        )
        state = transition
        lock.unlock()

        return performSleepPreparation(
            epoch: epoch,
            during: transition
        )
    }

    /// Wake is accepted only after the matching sleep preparation completed.
    /// Registration and outward availability are restored last, after display,
    /// permissions and media reconstruction have all succeeded.
    @discardableResult
    package func systemDidWake() -> Bool {
        lock.lock()
        guard case .sleeping(let epoch) = state else {
            lock.unlock()
            return false
        }
        let transition = HostAgentSleepWakeRecoveryState.recovering(
            epoch: epoch
        )
        state = transition
        lock.unlock()

        guard perform(
            .reenumerateDisplays,
            epoch: epoch,
            during: transition,
            operation: operations.reenumerateDisplays
        ), perform(
            .revalidatePermissions,
            epoch: epoch,
            during: transition,
            operation: operations.revalidatePermissions
        ), perform(
            .rebuildMedia,
            epoch: epoch,
            during: transition,
            operation: operations.rebuildMedia
        ), perform(
            .resumeRegistration,
            epoch: epoch,
            during: transition,
            operation: operations.resumeRegistration
        ), perform(
            .publishAvailable,
            epoch: epoch,
            during: transition,
            operation: operations.publishAvailable
        ) else {
            return false
        }
        return replace(
            transition,
            with: .running(epoch: epoch)
        )
    }

    package func cancel() {
        lock.lock()
        state = .cancelled
        lock.unlock()
    }

    /// Sleep preparation is cleanup: later safety steps must still run when an
    /// earlier closure reports failure. The first failed step becomes the
    /// terminal state only after availability withdrawal, media pause/flush
    /// and assertion release have all been attempted in order.
    private func performSleepPreparation(
        epoch: UInt64,
        during expected: HostAgentSleepWakeRecoveryState
    ) -> Bool {
        let orderedOperations: [(
            HostAgentSleepWakeRecoveryStep,
            @Sendable () -> Bool
        )] = [
            (.withdrawAvailability, operations.withdrawAvailability),
            (.publishSuspending, operations.publishSuspending),
            (.pauseMediaAndFlush, operations.pauseMediaAndFlush),
            (.releaseSleepAssertion, operations.releaseSleepAssertion),
        ]
        var firstFailure: HostAgentSleepWakeRecoveryStep?
        for (step, operation) in orderedOperations {
            lock.lock()
            guard state == expected else {
                lock.unlock()
                return false
            }
            lock.unlock()
            if !operation(), firstFailure == nil {
                firstFailure = step
            }
        }

        lock.lock()
        defer { lock.unlock() }
        guard state == expected else { return false }
        if let firstFailure {
            state = .failed(epoch: epoch, step: firstFailure)
            return false
        }
        state = .sleeping(epoch: epoch)
        return true
    }

    private func perform(
        _ step: HostAgentSleepWakeRecoveryStep,
        epoch: UInt64,
        during expected: HostAgentSleepWakeRecoveryState,
        operation: @Sendable () -> Bool
    ) -> Bool {
        lock.lock()
        guard state == expected else {
            lock.unlock()
            return false
        }
        lock.unlock()

        let succeeded = operation()

        lock.lock()
        defer { lock.unlock() }
        guard state == expected else { return false }
        guard succeeded else {
            state = .failed(epoch: epoch, step: step)
            return false
        }
        return true
    }

    private func replace(
        _ expected: HostAgentSleepWakeRecoveryState,
        with replacement: HostAgentSleepWakeRecoveryState
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == expected else { return false }
        state = replacement
        return true
    }
}
