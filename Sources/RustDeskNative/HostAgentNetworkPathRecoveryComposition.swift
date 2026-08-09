import CoreBridge
import Foundation

/// Same-lifetime product composition for normalized network-path recovery.
/// The system path adapter remains a separate ingress: this type owns only the
/// exact-generation trigger, authoritative convergence, and terminal failure
/// policy backed by the running HostAgent lifetime.
final class HostAgentNetworkPathRecoveryComposition: @unchecked Sendable {
    private let pollingOwner: HostAgentNetworkPathRecoveryPollingOwner
    private let triggerOwner: HostAgentNetworkPathRecoveryTriggerOwner
    private let requestTermination: @Sendable () -> Void

    init(
        lifetime: HostAgentProcessLifetime,
        expectedHostInstanceID: String,
        snapshotCoordinator: HostAgentSnapshotRefreshCoordinator
    ) {
        let requestTermination: @Sendable () -> Void = {
            [weak lifetime] in
            DispatchQueue.global(qos: .utility).async { [weak lifetime] in
                _ = lifetime?.requestTermination(reason: .error)
            }
        }
        let pollingOwner =
            HostAgentNetworkPathRecoveryPollingOwner.makeProduct(
                expectedHostInstanceID: expectedHostInstanceID,
                recover: { [weak lifetime] pathGeneration in
                    guard let lifetime else { return false }
                    do {
                        try lifetime.recoverNetworkPath(
                            generation: pathGeneration
                        )
                        return true
                    } catch {
                        return false
                    }
                },
                observe: { [weak lifetime] in
                    guard let lifetime else { return .failed }
                    do {
                        return .snapshot(try lifetime.copySnapshot())
                    } catch HostAgentProcessLifetimeAccessError.notRunning {
                        return .failed
                    } catch {
                        return .unavailable
                    }
                }
            )
        self.requestTermination = requestTermination
        self.pollingOwner = pollingOwner
        self.triggerOwner = HostAgentNetworkPathRecoveryTriggerOwner {
            pathGeneration, _ in
            pollingOwner.start(
                pathGeneration: pathGeneration,
                completion: { _, succeeded in
                    guard succeeded else {
                        requestTermination()
                        return
                    }
                    snapshotCoordinator.requestPoll()
                }
            )
        }
    }

    deinit {
        cancelAndWait()
    }

    func triggerSnapshot() -> HostAgentNetworkPathRecoveryTriggerState {
        triggerOwner.stateSnapshot()
    }

    func pollingSnapshot() -> HostAgentNetworkPathRecoveryPollingState {
        pollingOwner.stateSnapshot()
    }

    @discardableResult
    func consume(
        _ path: HostAgentNetworkPathSnapshot
    ) -> HostAgentNetworkPathRecoveryDisposition {
        triggerOwner.consume(path)
    }

    /// Stops new path admissions before draining any accepted restart and
    /// snapshot/completion work. Never call from a trigger or completion
    /// callback.
    func cancelAndWait() {
        triggerOwner.cancelAndWait()
        pollingOwner.cancelAndWait()
    }
}
