import CoreBridge
import Foundation
import VideoPipeline

private enum HostAgentSnapshotCopyAccessError: Error {
    case lifetimeUnavailable
}

/// Complete process-lifetime composition for the future `--host-agent` entry.
/// All accepted Host events are consumed by process-owned authorities; this
/// type deliberately neither prints diagnostics nor exits the process.
enum HostAgentProcess {
    static func run(
        expectedAgentBuildID: String,
        eventState: HostAgentEventState,
        snapshotState: HostAgentSnapshotState,
        mediaState: HostAgentMediaControlState
    ) -> HostAgentProcessRunResult {
        let snapshotCoordinator = HostAgentSnapshotRefreshCoordinator(
            state: snapshotState,
            eventState: eventState
        )
        let pollingOwner = HostAgentSnapshotPollingOwner(
            snapshotCoordinator: snapshotCoordinator
        )
        let mediaPipelineOwner = HostAgentMediaPipelineOwner()
        let sleepWakeRecoveryOwner =
            HostAgentSleepWakeRecoveryProcessOwner()
        let networkPathRecoveryOwner =
            HostAgentNetworkPathRecoveryProcessOwner()
        let recoveryEvidenceOwner =
            HostRecoveryTransitionEvidenceProcessOwner()
        return HostAgentProcessRunner.run(
            installTerminationIngress: {
                try HostAgentProcessSignalController()
            },
            startRuntime: {
                let result = HostAgentProcessStartup.prepare(
                    expectedAgentBuildID: expectedAgentBuildID,
                    eventState: eventState,
                    snapshotState: snapshotState,
                    prepareTermination: {
                        networkPathRecoveryOwner.cancelAndWait()
                        sleepWakeRecoveryOwner.cancelAndWait()
                        recoveryEvidenceOwner.cancelAndWait()
                        mediaState.cancelAndWait()
                        mediaPipelineOwner.cancelAndWait()
                        pollingOwner.cancel()
                    },
                    onEvent: { event in
                        eventState.consume(event) { event, sequence in
                            snapshotCoordinator.requestRefresh(
                                eventSequence: sequence,
                                hostInstanceID: event.hostInstanceId
                            )
                            mediaState.consume(
                                event,
                                eventSequence: sequence,
                                onAccepted: { control in
                                    mediaPipelineOwner.handle(control)
                                }
                            )
                            mediaPipelineOwner.consume(event)
                        }
                    }
                )
                guard case .success(let lifetime) = result else {
                    return result
                }
                guard snapshotCoordinator.bind(
                    copySnapshot: { [weak lifetime] in
                        guard let lifetime else {
                            throw HostAgentSnapshotCopyAccessError.lifetimeUnavailable
                        }
                        return try lifetime.copySnapshot()
                    },
                    onIdentityInvalidationRequired: { [weak lifetime] _ in
                        guard let lifetime else { return }
                        try? lifetime.invalidateXPCIdentity()
                    }
                ) else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard let hostInstanceID = snapshotState.snapshot().hostInstanceID
                else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                _ = recoveryEvidenceOwner.configure(
                    hostInstanceID: hostInstanceID,
                    buildIdentity: expectedAgentBuildID
                )
                guard (try? lifetime.bindXPCIdentity(
                    hostInstanceID: hostInstanceID
                )) == .bound else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard mediaPipelineOwner.start(
                        lifetime: lifetime,
                        hostInstanceID: hostInstanceID
                      )
                else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard sleepWakeRecoveryOwner.install(
                    lifetime: lifetime,
                    expectedHostInstanceID: hostInstanceID,
                    mediaPipelineOwner: mediaPipelineOwner,
                    snapshotCoordinator: snapshotCoordinator,
                    recoveryEvidenceOwner: recoveryEvidenceOwner
                ) else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard networkPathRecoveryOwner.install(
                    lifetime: lifetime,
                    expectedHostInstanceID: hostInstanceID,
                    snapshotCoordinator: snapshotCoordinator,
                    recoveryEvidenceOwner: recoveryEvidenceOwner
                ) else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard pollingOwner.start() else {
                    _ = lifetime.requestTermination(reason: .error)
                    _ = lifetime.waitUntilTerminated()
                    return .failure(HostAgentStartupFailure(kind: .internalFailure))
                }
                guard (try? lifetime.activateXPCListener()) == true else {
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
