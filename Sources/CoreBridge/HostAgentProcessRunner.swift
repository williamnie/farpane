import Foundation

/// Sanitized terminal result for the HostAgent process orchestration layer.
/// It retains neither implementation errors nor configuration values.
public enum HostAgentProcessRunResult: Equatable, Sendable {
    case stopped
    case startupFailed(HostAgentStartupFailure)
    case stopFailed
    case internalFailure

    public var exitCode: Int32 {
        switch self {
        case .stopped:
            return 0
        case .startupFailed(let failure):
            return failure.exitCode
        case .stopFailed, .internalFailure:
            return 70 // EX_SOFTWARE
        }
    }

    public var diagnostic: String? {
        switch self {
        case .stopped:
            return nil
        case .startupFailed(let failure):
            return failure.diagnostic
        case .stopFailed:
            return "FarPane HostAgent failed to stop cleanly."
        case .internalFailure:
            return "FarPane HostAgent encountered an internal lifecycle error."
        }
    }
}

/// Runs one HostAgent lifetime in strict process order: termination ingress is
/// installed before startup, bound to the successful runtime, then cancelled
/// only after startup failure or a terminal stop outcome.
public enum HostAgentProcessRunner {
    public static func run<Runtime, TerminationIngress>(
        installTerminationIngress: () throws -> TerminationIngress,
        startRuntime: () -> Result<Runtime, HostAgentStartupFailure>,
        bindTermination: (TerminationIngress, Runtime) -> Bool,
        requestTermination: (Runtime, HostStopReason) -> Bool,
        waitUntilTerminated: (Runtime) -> HostAgentProcessTerminationOutcome,
        cancelTerminationIngress: (TerminationIngress) -> Void
    ) -> HostAgentProcessRunResult {
        let ingress: TerminationIngress
        do {
            ingress = try installTerminationIngress()
        } catch {
            return .internalFailure
        }
        defer {
            cancelTerminationIngress(ingress)
        }

        let runtime: Runtime
        switch startRuntime() {
        case .success(let startedRuntime):
            runtime = startedRuntime
        case .failure(let failure):
            return .startupFailed(failure)
        }

        guard bindTermination(ingress, runtime) else {
            _ = requestTermination(runtime, .error)
            _ = waitUntilTerminated(runtime)
            return .internalFailure
        }

        switch waitUntilTerminated(runtime).status {
        case .stopped:
            return .stopped
        case .stopFailed:
            return .stopFailed
        }
    }
}
