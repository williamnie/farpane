import CoreBridge
import Foundation

/// Product lifetime owner returned only after HostAgent runtime startup has
/// succeeded. It retains the runtime until the one terminal stop attempt.
final class HostAgentProcessLifetime: @unchecked Sendable {
    private let gate: HostAgentProcessLifetimeGate<HostAgentProcessRuntime>

    init(
        runtime: HostAgentProcessRuntime,
        prepareTermination: @escaping () -> Void = {}
    ) {
        self.gate = HostAgentProcessLifetimeGate(
            runtime: runtime,
            prepareTermination: prepareTermination,
            stopRuntime: { runtime, reason in
                try runtime.stop(reason: reason)
            }
        )
    }

    @discardableResult
    func requestTermination(reason: HostStopReason) -> Bool {
        gate.requestTermination(reason: reason)
    }

    func waitUntilTerminated() -> HostAgentProcessTerminationOutcome {
        gate.waitUntilTerminated()
    }

    func copySnapshot() throws -> HostCoreSnapshot {
        try gate.withRunningRuntime { runtime in
            try runtime.copySnapshot()
        }
    }
}
