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
        mediaState: HostAgentMediaControlState,
        concurrencyState: HostAgentConcurrencyObservationState
    ) -> HostAgentProcessRunResult {
        let concurrencyEvidenceOwner =
            HostViewerConcurrencyEvidenceProcessOwner()
        _ = concurrencyEvidenceOwner.configureHostAgent(
            expectedAgentBuildID: expectedAgentBuildID
        )
        defer {
            _ = concurrencyEvidenceOwner.terminateAndWait()
        }
        let snapshotCoordinator = HostAgentSnapshotRefreshCoordinator(
            state: snapshotState,
            eventState: eventState
        )
        let eventQueue = DispatchQueue(
            label: "io.farpane.host-agent.startup-events",
            qos: .userInitiated
        )
        let pollingOwner = HostAgentSnapshotPollingOwner(
            snapshotCoordinator: snapshotCoordinator
        )
        let sleepWakeRecoveryOwner =
            HostAgentSleepWakeRecoveryProcessOwner()
        let networkPathRecoveryOwner =
            HostAgentNetworkPathRecoveryProcessOwner()
        let recoveryEvidenceOwner =
            HostRecoveryTransitionEvidenceProcessOwner()
        let mediaPipelineOwner = HostAgentMediaPipelineOwner(
            recoveryEvidenceOwner: recoveryEvidenceOwner
        )
        return HostAgentProcessRunner.run(
            installTerminationIngress: {
                try HostAgentProcessSignalController()
            },
            startRuntime: {
                let result = HostAgentProcessStartup.prepare(
                    expectedAgentBuildID: expectedAgentBuildID,
                    eventState: eventState,
                    snapshotState: snapshotState,
                    eventQueue: eventQueue,
                    prepareTermination: {
                        networkPathRecoveryOwner.cancelAndWait()
                        sleepWakeRecoveryOwner.cancelAndWait()
                        mediaState.cancelAndWait()
                        mediaPipelineOwner.cancelAndWait()
                        recoveryEvidenceOwner.cancelAndWait()
                        pollingOwner.cancel()
                        eventQueue.sync {
                            concurrencyState.cancelAndWait()
                        }
                    },
                    onEvent: { event in
                        eventState.consume(event) { event, sequence in
                            _ = concurrencyState.observe(event: event)
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
                if let identity = try? lifetime.concurrencyEvidenceIdentity() {
                    _ = concurrencyState.bind { observation in
                        recordConcurrencyObservation(
                            observation,
                            identity: identity,
                            owner: concurrencyEvidenceOwner
                        )
                    }
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
                    },
                    onSnapshotPublished: { snapshot in
                        eventQueue.async {
                            _ = concurrencyState.observe(snapshot: snapshot)
                        }
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
                eventQueue.sync {
                    _ = concurrencyState.observe(
                        snapshot: snapshotState.snapshot()
                    )
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

    private static func recordConcurrencyObservation(
        _ observation: HostAgentConcurrencyObservation,
        identity: HostAgentProcessEvidenceIdentity,
        owner: HostViewerConcurrencyEvidenceProcessOwner
    ) {
        let state: HostViewerConcurrencyHostState
        switch observation.state {
        case .readyZeroInbound:
            state = .readyZeroInbound
        case .inboundMediaActive:
            state = .inboundMediaActive
        case .disconnected:
            state = .disconnected
        }
        _ = owner.observeHostAgentRuntimeState(
            state: state,
            hostInstanceID: observation.hostInstanceID,
            agentBootID: identity.agentBootID,
            configRevision: identity.configRevision,
            agentBuildID: identity.agentBuildID,
            sourceGeneration: observation.sourceGeneration
        )
    }
}
