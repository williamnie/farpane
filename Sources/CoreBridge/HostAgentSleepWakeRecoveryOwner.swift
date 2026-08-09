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
    case waitingForMedia(epoch: UInt64)
    case restoringRegistration(epoch: UInt64)
    case waitingForRegistration(epoch: UInt64)
    case failed(epoch: UInt64, step: HostAgentSleepWakeRecoveryStep)
    case cancelled
}

package typealias HostAgentSleepWakeMediaRecoveryCompletion = @Sendable (
    _ epoch: UInt64,
    _ succeeded: Bool
) -> Void

package typealias HostAgentSleepWakeRegistrationRecoveryCompletion = @Sendable (
    _ epoch: UInt64,
    _ succeeded: Bool
) -> Void

/// Operations owned by the future product adapter. Media and registration
/// recovery are asynchronous boundaries; each begin closure must return false
/// when no matching completion can be delivered. Callbacks must not expose
/// implementation errors, TCC details, display names, connection IDs or frame
/// contents.
package struct HostAgentSleepWakeRecoveryOperations: Sendable {
    package let withdrawAvailability: @Sendable (_ epoch: UInt64) -> Bool
    package let publishSuspending: @Sendable (_ epoch: UInt64) -> Bool
    package let pauseMediaAndFlush: @Sendable () -> Bool
    package let releaseSleepAssertion: @Sendable (_ epoch: UInt64) -> Bool
    package let reenumerateDisplays: @Sendable () -> Bool
    package let revalidatePermissions: @Sendable () -> Bool
    package let beginMediaRecovery: @Sendable (
        _ epoch: UInt64,
        _ completion: @escaping HostAgentSleepWakeMediaRecoveryCompletion
    ) -> Bool
    package let beginRegistrationRecovery: @Sendable (
        _ epoch: UInt64,
        _ completion: @escaping HostAgentSleepWakeRegistrationRecoveryCompletion
    ) -> Bool
    package let publishAvailable: @Sendable (_ epoch: UInt64) -> Bool

    package init(
        withdrawAvailability: @escaping @Sendable (_ epoch: UInt64) -> Bool,
        publishSuspending: @escaping @Sendable (_ epoch: UInt64) -> Bool,
        pauseMediaAndFlush: @escaping @Sendable () -> Bool,
        releaseSleepAssertion: @escaping @Sendable (_ epoch: UInt64) -> Bool,
        reenumerateDisplays: @escaping @Sendable () -> Bool,
        revalidatePermissions: @escaping @Sendable () -> Bool,
        beginMediaRecovery: @escaping @Sendable (
            _ epoch: UInt64,
            _ completion: @escaping HostAgentSleepWakeMediaRecoveryCompletion
        ) -> Bool,
        beginRegistrationRecovery: @escaping @Sendable (
            _ epoch: UInt64,
            _ completion: @escaping HostAgentSleepWakeRegistrationRecoveryCompletion
        ) -> Bool,
        publishAvailable: @escaping @Sendable (_ epoch: UInt64) -> Bool
    ) {
        self.withdrawAvailability = withdrawAvailability
        self.publishSuspending = publishSuspending
        self.pauseMediaAndFlush = pauseMediaAndFlush
        self.releaseSleepAssertion = releaseSleepAssertion
        self.reenumerateDisplays = reenumerateDisplays
        self.revalidatePermissions = revalidatePermissions
        self.beginMediaRecovery = beginMediaRecovery
        self.beginRegistrationRecovery = beginRegistrationRecovery
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
    private var mediaStartInFlightEpoch: UInt64?
    private var deferredMediaCompletion: (
        epoch: UInt64,
        succeeded: Bool
    )?
    private var registrationStartInFlightEpoch: UInt64?
    private var deferredRegistrationCompletion: (
        epoch: UInt64,
        succeeded: Bool
    )?

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
    /// Display and permission checks run synchronously. A successful media
    /// begin moves to waitingForMedia; registration and outward availability
    /// remain withdrawn until the exact epoch completes successfully.
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
        ) else {
            return false
        }
        return beginMediaRecovery(
            epoch: epoch,
            during: transition
        )
    }

    package func cancel() {
        lock.lock()
        state = .cancelled
        mediaStartInFlightEpoch = nil
        deferredMediaCompletion = nil
        registrationStartInFlightEpoch = nil
        deferredRegistrationCompletion = nil
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
            (.withdrawAvailability, {
                self.operations.withdrawAvailability(epoch)
            }),
            (.publishSuspending, {
                self.operations.publishSuspending(epoch)
            }),
            (.pauseMediaAndFlush, operations.pauseMediaAndFlush),
            (.releaseSleepAssertion, {
                self.operations.releaseSleepAssertion(epoch)
            }),
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

    private func beginMediaRecovery(
        epoch: UInt64,
        during expected: HostAgentSleepWakeRecoveryState
    ) -> Bool {
        let waiting = HostAgentSleepWakeRecoveryState.waitingForMedia(
            epoch: epoch
        )
        lock.lock()
        guard state == expected,
              mediaStartInFlightEpoch == nil,
              deferredMediaCompletion == nil
        else {
            lock.unlock()
            return false
        }
        state = waiting
        mediaStartInFlightEpoch = epoch
        lock.unlock()

        let accepted = operations.beginMediaRecovery(
            epoch,
            { [weak self] completedEpoch, succeeded in
                self?.mediaRecoveryDidComplete(
                    epoch: completedEpoch,
                    succeeded: succeeded
                )
            }
        )
        return finishMediaRecoveryBegin(
            epoch: epoch,
            waiting: waiting,
            accepted: accepted
        )
    }

    /// Completion may be delivered synchronously from beginMediaRecovery.
    /// Buffering it until begin returns prevents a callback from advancing
    /// registration when the adapter ultimately rejects the start.
    private func mediaRecoveryDidComplete(
        epoch: UInt64,
        succeeded: Bool
    ) {
        lock.lock()
        if mediaStartInFlightEpoch == epoch {
            guard state == .waitingForMedia(epoch: epoch),
                  deferredMediaCompletion == nil
            else {
                lock.unlock()
                return
            }
            deferredMediaCompletion = (epoch, succeeded)
            lock.unlock()
            return
        }
        lock.unlock()

        _ = finishMediaRecovery(epoch: epoch, succeeded: succeeded)
    }

    private func finishMediaRecoveryBegin(
        epoch: UInt64,
        waiting: HostAgentSleepWakeRecoveryState,
        accepted: Bool
    ) -> Bool {
        lock.lock()
        guard state == waiting,
              mediaStartInFlightEpoch == epoch
        else {
            lock.unlock()
            return false
        }
        mediaStartInFlightEpoch = nil
        let deferred = deferredMediaCompletion
        deferredMediaCompletion = nil
        guard accepted else {
            state = .failed(epoch: epoch, step: .rebuildMedia)
            lock.unlock()
            return false
        }
        lock.unlock()

        guard let deferred else { return true }
        return finishMediaRecovery(
            epoch: deferred.epoch,
            succeeded: deferred.succeeded
        )
    }

    private func finishMediaRecovery(
        epoch: UInt64,
        succeeded: Bool
    ) -> Bool {
        let waiting = HostAgentSleepWakeRecoveryState.waitingForMedia(
            epoch: epoch
        )
        let restoring = HostAgentSleepWakeRecoveryState.restoringRegistration(
            epoch: epoch
        )
        lock.lock()
        guard state == waiting,
              mediaStartInFlightEpoch == nil,
              deferredMediaCompletion == nil
        else {
            lock.unlock()
            return false
        }
        guard succeeded else {
            state = .failed(epoch: epoch, step: .rebuildMedia)
            lock.unlock()
            return false
        }
        state = restoring
        lock.unlock()

        return beginRegistrationRecovery(
            epoch: epoch,
            during: restoring
        )
    }

    private func beginRegistrationRecovery(
        epoch: UInt64,
        during expected: HostAgentSleepWakeRecoveryState
    ) -> Bool {
        let waiting = HostAgentSleepWakeRecoveryState.waitingForRegistration(
            epoch: epoch
        )
        lock.lock()
        guard state == expected,
              registrationStartInFlightEpoch == nil,
              deferredRegistrationCompletion == nil
        else {
            lock.unlock()
            return false
        }
        state = waiting
        registrationStartInFlightEpoch = epoch
        lock.unlock()

        let accepted = operations.beginRegistrationRecovery(
            epoch,
            { [weak self] completedEpoch, succeeded in
                self?.registrationRecoveryDidComplete(
                    epoch: completedEpoch,
                    succeeded: succeeded
                )
            }
        )
        return finishRegistrationRecoveryBegin(
            epoch: epoch,
            waiting: waiting,
            accepted: accepted
        )
    }

    private func registrationRecoveryDidComplete(
        epoch: UInt64,
        succeeded: Bool
    ) {
        lock.lock()
        if registrationStartInFlightEpoch == epoch {
            guard state == .waitingForRegistration(epoch: epoch),
                  deferredRegistrationCompletion == nil
            else {
                lock.unlock()
                return
            }
            deferredRegistrationCompletion = (epoch, succeeded)
            lock.unlock()
            return
        }
        lock.unlock()

        _ = finishRegistrationRecovery(epoch: epoch, succeeded: succeeded)
    }

    private func finishRegistrationRecoveryBegin(
        epoch: UInt64,
        waiting: HostAgentSleepWakeRecoveryState,
        accepted: Bool
    ) -> Bool {
        lock.lock()
        guard state == waiting,
              registrationStartInFlightEpoch == epoch
        else {
            lock.unlock()
            return false
        }
        registrationStartInFlightEpoch = nil
        let deferred = deferredRegistrationCompletion
        deferredRegistrationCompletion = nil
        guard accepted else {
            state = .failed(epoch: epoch, step: .resumeRegistration)
            lock.unlock()
            return false
        }
        lock.unlock()

        guard let deferred else { return true }
        return finishRegistrationRecovery(
            epoch: deferred.epoch,
            succeeded: deferred.succeeded
        )
    }

    private func finishRegistrationRecovery(
        epoch: UInt64,
        succeeded: Bool
    ) -> Bool {
        let waiting = HostAgentSleepWakeRecoveryState.waitingForRegistration(
            epoch: epoch
        )
        let restoring = HostAgentSleepWakeRecoveryState.restoringRegistration(
            epoch: epoch
        )
        lock.lock()
        guard state == waiting,
              registrationStartInFlightEpoch == nil,
              deferredRegistrationCompletion == nil
        else {
            lock.unlock()
            return false
        }
        guard succeeded else {
            state = .failed(epoch: epoch, step: .resumeRegistration)
            lock.unlock()
            return false
        }
        state = restoring
        lock.unlock()

        guard perform(
            .publishAvailable,
            epoch: epoch,
            during: restoring,
            operation: {
                self.operations.publishAvailable(epoch)
            }
        ) else {
            return false
        }
        return replace(
            restoring,
            with: .running(epoch: epoch)
        )
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
