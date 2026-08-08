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

package enum HostAgentProcessTerminalResult: Equatable, Sendable {
    case unavailable
    case entryRejected(HostAgentProcessEntryFailure)
    case process(HostAgentProcessRunResult)

    fileprivate var exitCode: Int32 {
        switch self {
        case .unavailable:
            return 69 // EX_UNAVAILABLE
        case .entryRejected(let failure):
            return failure.exitCode
        case .process(let result):
            return result.exitCode
        }
    }

    fileprivate var diagnostic: String? {
        switch self {
        case .unavailable:
            return "FarPane HostAgent runtime is not available in this build."
        case .entryRejected(let failure):
            return failure.diagnostic
        case .process(let result):
            return result.diagnostic
        }
    }
}

/// Writes at most one fixed, sanitized diagnostic line and returns the stable
/// sysexits value that the executable should use. Diagnostic I/O failure never
/// changes the process result or retains an underlying Foundation error.
package enum HostAgentProcessTerminalReporter {
    @discardableResult
    package static func report(
        _ result: HostAgentProcessTerminalResult,
        to output: FileHandle = .standardError
    ) -> Int32 {
        if let diagnostic = result.diagnostic,
           let bytes = (diagnostic + "\n").data(using: .utf8)
        {
            try? output.write(contentsOf: bytes)
        }
        return result.exitCode
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
