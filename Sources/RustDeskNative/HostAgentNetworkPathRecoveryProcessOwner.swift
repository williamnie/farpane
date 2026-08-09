import CoreBridge
import Foundation

enum HostAgentNetworkPathRecoveryProcessState: Equatable, Sendable {
    case idle
    case installing
    case installed
    case cancelling
    case cancelled
}

/// Process-lifetime owner for the network recovery composition. It deliberately
/// has no system path ingress; the subsequent path adapter will feed normalized
/// snapshots only through `consume`.
final class HostAgentNetworkPathRecoveryProcessOwner: @unchecked Sendable {
    private let condition = NSCondition()
    private var state: HostAgentNetworkPathRecoveryProcessState = .idle
    private var cancellationRequested = false
    private var composition: HostAgentNetworkPathRecoveryComposition?

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

        let composition = HostAgentNetworkPathRecoveryComposition(
            lifetime: lifetime,
            expectedHostInstanceID: expectedHostInstanceID,
            snapshotCoordinator: snapshotCoordinator
        )

        condition.lock()
        if cancellationRequested {
            condition.unlock()
            composition.cancelAndWait()
            condition.lock()
            state = .cancelled
            condition.broadcast()
            condition.unlock()
            return false
        }
        self.composition = composition
        state = .installed
        condition.broadcast()
        condition.unlock()
        return true
    }

    @discardableResult
    func consume(
        _ path: HostAgentNetworkPathSnapshot
    ) -> HostAgentNetworkPathRecoveryDisposition {
        guard let composition = installedComposition() else {
            return .rejected
        }
        return composition.consume(path)
    }

    func triggerSnapshot() -> HostAgentNetworkPathRecoveryTriggerState? {
        installedComposition()?.triggerSnapshot()
    }

    func pollingSnapshot() -> HostAgentNetworkPathRecoveryPollingState? {
        installedComposition()?.pollingSnapshot()
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
            let composition = self.composition
            self.composition = nil
            condition.unlock()

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
