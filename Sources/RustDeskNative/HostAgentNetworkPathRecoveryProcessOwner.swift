import CoreBridge
import Foundation
import VideoPipeline

enum HostAgentNetworkPathRecoveryProcessState: Equatable, Sendable {
    case idle
    case installing
    case installed
    case cancelling
    case cancelled
}

/// Process-lifetime owner for the recovery composition and its single system
/// path ingress. Installation and teardown keep both under the same Host
/// lifetime boundary.
final class HostAgentNetworkPathRecoveryProcessOwner: @unchecked Sendable {
    private let condition = NSCondition()
    private var state: HostAgentNetworkPathRecoveryProcessState = .idle
    private var cancellationRequested = false
    private var composition: HostAgentNetworkPathRecoveryComposition?
    private var pathIngress: HostAgentNWPathMonitorIngress?

    deinit {
        cancelAndWait()
    }

    func stateSnapshot() -> HostAgentNetworkPathRecoveryProcessState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    func install(
        lifetime: HostAgentProcessLifetime,
        expectedHostInstanceID: String,
        snapshotCoordinator: HostAgentSnapshotRefreshCoordinator,
        recoveryEvidenceOwner: HostRecoveryTransitionEvidenceProcessOwner
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

        let composition = HostAgentNetworkPathRecoveryComposition(
            lifetime: lifetime,
            expectedHostInstanceID: expectedHostInstanceID,
            snapshotCoordinator: snapshotCoordinator,
            recoveryEvidenceOwner: recoveryEvidenceOwner
        )
        let pathIngress = HostAgentNWPathMonitorIngress.makeProduct(
            deliverPath: { path in
                composition.consume(path) != .rejected
            },
            onFailure: { [weak lifetime] in
                _ = lifetime?.requestTermination(reason: .error)
            }
        )
        guard pathIngress.start() else {
            pathIngress.cancelAndWait()
            composition.cancelAndWait()
            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            return false
        }

        condition.lock()
        if cancellationRequested {
            condition.unlock()
            pathIngress.cancelAndWait()
            composition.cancelAndWait()
            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            return false
        }
        self.composition = composition
        self.pathIngress = pathIngress
        state = .installed
        condition.broadcast()
        condition.unlock()
        return true
    }

    func triggerSnapshot() -> HostAgentNetworkPathRecoveryTriggerState? {
        installedComposition()?.triggerSnapshot()
    }

    func pollingSnapshot() -> HostAgentNetworkPathRecoveryPollingState? {
        installedComposition()?.pollingSnapshot()
    }

    func pathIngressSnapshot() -> HostAgentNWPathMonitorIngressState? {
        condition.lock()
        defer { condition.unlock() }
        guard state == .installed else { return nil }
        return pathIngress?.stateSnapshot()
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
            let pathIngress = self.pathIngress
            let composition = self.composition
            self.pathIngress = nil
            self.composition = nil
            condition.unlock()

            pathIngress?.cancelAndWait()
            composition?.cancelAndWait()

            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }

    private func installedComposition()
        -> HostAgentNetworkPathRecoveryComposition?
    {
        condition.lock()
        defer { condition.unlock() }
        guard state == .installed else { return nil }
        return composition
    }
}
