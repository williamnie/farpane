import ConnectionCatalog
import CoreBridge
import Foundation

/// Prepares one HostAgent runtime and reduces every thrown implementation
/// error to a fixed, non-sensitive process result. The actual Agent entry/run
/// loop remains intentionally disabled until its lifecycle owner is complete.
enum HostAgentProcessStartup {
    static func prepare(
        expectedAgentBuildID: String,
        eventState: HostAgentEventState,
        snapshotState: HostAgentSnapshotState,
        eventQueue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.startup-events",
            qos: .userInitiated
        ),
        prepareTermination: @escaping () -> Void = {},
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) -> Result<HostAgentProcessLifetime, HostAgentStartupFailure> {
        HostAgentProcessStartupRunner.start(
            startRuntime: {
                let runtime = try HostAgentProcessRuntime.start(
                    expectedAgentBuildID: expectedAgentBuildID,
                    eventState: eventState,
                    snapshotState: snapshotState,
                    eventQueue: eventQueue,
                    onEvent: onEvent
                )
                return HostAgentProcessLifetime(
                    runtime: runtime,
                    prepareTermination: prepareTermination
                )
            },
            classifyError: classify
        )
    }

    private static func classify(_ error: Error) -> HostAgentStartupFailure {
        if let leaseError = error as? HostAgentSingleWriterLeaseError {
            switch leaseError {
            case .alreadyHeld:
                return HostAgentStartupFailure(kind: .alreadyRunning)
            default:
                return HostAgentStartupFailure(kind: .runtimeOwnershipUnavailable)
            }
        }
        if error is HostAgentSingleWriterLeaseRecordError {
            return HostAgentStartupFailure(kind: .runtimeOwnershipUnavailable)
        }
        if error is HostAgentBootstrapProductLayoutError
            || error is HostAgentBootstrapProductDirectoryPreparerError
            || error is HostAgentBootstrapLaunchPreflightError
            || error is HostAgentBootstrapConfigurationReaderError
            || error is HostAgentBootstrapConfigurationError
        {
            return HostAgentStartupFailure(kind: .configurationUnavailable)
        }
        if error is HostAgentBundledCoreLocatorError {
            return HostAgentStartupFailure(kind: .coreUnavailable)
        }
        if let controlError = error as? HostControlError {
            switch controlError {
            case .load(_),
                 .hostSurfaceUnavailable,
                 .abiMismatch(_),
                 .mediaABIMismatch(_),
                 .invalidUpstreamCommit(_):
                return HostAgentStartupFailure(kind: .coreUnavailable)
            case .configRoot(_), .create(_), .start(_):
                return HostAgentStartupFailure(kind: .runtimeStartupFailed)
            default:
                return HostAgentStartupFailure(kind: .internalFailure)
            }
        }
        return HostAgentStartupFailure(kind: .internalFailure)
    }
}
