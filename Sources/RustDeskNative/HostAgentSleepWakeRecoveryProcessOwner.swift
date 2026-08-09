import CoreBridge
import Foundation

enum HostAgentSleepWakeRecoveryProcessState: Equatable, Sendable {
    case idle
    case installing
    case installed
    case cancelling
    case cancelled
}

/// Process-lifetime owner for the complete recovery composition and its system
/// notification ingress. It hard-binds projection publication to the same
/// serialized snapshot coordinator used by event and periodic refreshes.
final class HostAgentSleepWakeRecoveryProcessOwner: @unchecked Sendable {
    private let condition = NSCondition()
    private var state: HostAgentSleepWakeRecoveryProcessState = .idle
    private var cancellationRequested = false
    private var composition: HostAgentSleepWakeRecoveryComposition?
    private var notificationIngress:
        HostAgentNSWorkspaceSleepWakeIngress?

    deinit {
        cancelAndWait()
    }

    func stateSnapshot() -> HostAgentSleepWakeRecoveryProcessState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    func install(
        lifetime: HostAgentProcessLifetime,
        expectedHostInstanceID: String,
        mediaPipelineOwner: HostAgentMediaPipelineOwner,
        snapshotCoordinator: HostAgentSnapshotRefreshCoordinator
    ) -> Bool {
        condition.lock()
        guard state == .idle,
              !expectedHostInstanceID.isEmpty
        else {
            condition.unlock()
            return false
        }
        state = .installing
        condition.unlock()

        let composition = HostAgentSleepWakeRecoveryComposition(
            mediaPipelineOwner: mediaPipelineOwner,
            displayTCCAuthority:
                HostAgentDisplayTCCRecoveryAuthority.makeProduct(),
            lifetime: lifetime,
            expectedHostInstanceID: expectedHostInstanceID,
            operations: HostAgentSleepWakeRecoveryProductOperations(
                publishSuspending: { epoch in
                    snapshotCoordinator.publishRecoverySnapshot(
                        expectedHostInstanceID: expectedHostInstanceID,
                        epoch: epoch,
                        recoveryStatus: .suspending,
                        registrationStatus: "suspending"
                    )
                },
                publishAvailable: { epoch in
                    snapshotCoordinator.publishRecoverySnapshot(
                        expectedHostInstanceID: expectedHostInstanceID,
                        epoch: epoch,
                        recoveryStatus: .running,
                        registrationStatus: "ready"
                    )
                }
            )
        )
        let notificationIngress =
            HostAgentNSWorkspaceSleepWakeIngress.makeProduct(
                composition: composition,
                lifetime: lifetime
            )
        guard notificationIngress.start() else {
            notificationIngress.cancelAndWait()
            composition.cancel()
            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            return false
        }

        condition.lock()
        if cancellationRequested {
            condition.unlock()
            notificationIngress.cancelAndWait()
            composition.cancel()
            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            return false
        }
        self.composition = composition
        self.notificationIngress = notificationIngress
        state = .installed
        condition.broadcast()
        condition.unlock()
        return true
    }

    @discardableResult
    func systemWillSleep() -> Bool {
        installedComposition()?.systemWillSleep() ?? false
    }

    @discardableResult
    func systemDidWake() -> Bool {
        installedComposition()?.systemDidWake() ?? false
    }

    func recoverySnapshot() -> HostAgentSleepWakeRecoveryState? {
        installedComposition()?.snapshot()
    }

    func cancelAndWait() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while state == .cancelling {
                condition.wait()
            }
            condition.unlock()
            return
        case .installing:
            cancellationRequested = true
            while state == .installing {
                condition.wait()
            }
            condition.unlock()
            return
        case .idle:
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            return
        case .installed:
            state = .cancelling
            let notificationIngress = self.notificationIngress
            let composition = self.composition
            self.notificationIngress = nil
            self.composition = nil
            condition.unlock()

            notificationIngress?.cancelAndWait()
            composition?.cancel()

            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }

    private func installedComposition()
        -> HostAgentSleepWakeRecoveryComposition?
    {
        condition.lock()
        defer { condition.unlock() }
        guard state == .installed else { return nil }
        return composition
    }
}
