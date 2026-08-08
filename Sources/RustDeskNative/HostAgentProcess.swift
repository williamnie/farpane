import CoreBridge
import Foundation

private enum HostAgentSnapshotCopyAccessError: Error {
    case lifetimeUnavailable
}

/// Complete process-lifetime composition for the future `--host-agent` entry.
/// The caller must provide the authoritative Host event consumer; this type
/// deliberately neither prints diagnostics nor exits the process.
enum HostAgentProcess {
    static func run(
        eventState: HostAgentEventState,
        snapshotState: HostAgentSnapshotState,
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) -> HostAgentProcessRunResult {
        let snapshotCoordinator = HostAgentSnapshotRefreshCoordinator(
            state: snapshotState
        )
        let pollingOwner = HostAgentSnapshotPollingOwner(
            snapshotCoordinator: snapshotCoordinator
        )
        return HostAgentProcessRunner.run(
            installTerminationIngress: {
                try HostAgentProcessSignalController()
            },
            startRuntime: {
                let result = HostAgentProcessStartup.prepare(
                    prepareTermination: pollingOwner.cancel,
                    onEvent: { event in
                        eventState.consume(event) { event, sequence in
                            snapshotCoordinator.requestRefresh(
                                eventSequence: sequence,
                                hostInstanceID: event.hostInstanceId
                            )
                            onEvent(event)
                        }
                    }
                )
                guard case .success(let lifetime) = result else {
                    return result
                }
                guard snapshotCoordinator.bind(copySnapshot: { [weak lifetime] in
                    guard let lifetime else {
                        throw HostAgentSnapshotCopyAccessError.lifetimeUnavailable
                    }
                    return try lifetime.copySnapshot()
                }) else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard pollingOwner.start() else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                return .success(lifetime)
            },
            bindTermination: { controller, lifetime in
                controller.bind(lifetime: lifetime)
            },
            requestTermination: { lifetime, reason in
                lifetime.requestTermination(reason: reason)
            },
            waitUntilTerminated: { lifetime in
                lifetime.waitUntilTerminated()
            },
            cancelTerminationIngress: { controller in
                controller.cancel()
            }
        )
    }
}
