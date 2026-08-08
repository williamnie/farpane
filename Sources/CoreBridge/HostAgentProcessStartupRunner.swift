import Foundation

/// Sanitized process-level startup failure. It intentionally retains no
/// underlying Error, path, server value, key, build ID or free-form message.
public struct HostAgentStartupFailure: Error, Equatable, Sendable,
    CustomStringConvertible
{
    public enum Kind: String, Equatable, Sendable {
        case configurationUnavailable
        case runtimeOwnershipUnavailable
        case alreadyRunning
        case coreUnavailable
        case runtimeStartupFailed
        case internalFailure
    }

    public let kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }

    public var exitCode: Int32 {
        switch kind {
        case .configurationUnavailable:
            return 78 // EX_CONFIG
        case .runtimeOwnershipUnavailable, .alreadyRunning:
            return 75 // EX_TEMPFAIL
        case .coreUnavailable:
            return 69 // EX_UNAVAILABLE
        case .runtimeStartupFailed, .internalFailure:
            return 70 // EX_SOFTWARE
        }
    }

    public var diagnostic: String {
        switch kind {
        case .configurationUnavailable:
            return "FarPane HostAgent configuration is unavailable."
        case .runtimeOwnershipUnavailable:
            return "FarPane HostAgent runtime ownership is unavailable."
        case .alreadyRunning:
            return "FarPane HostAgent is already running."
        case .coreUnavailable:
            return "FarPane HostAgent Core is unavailable or incompatible."
        case .runtimeStartupFailed:
            return "FarPane HostAgent failed to start."
        case .internalFailure:
            return "FarPane HostAgent encountered an internal startup error."
        }
    }

    public var description: String { diagnostic }
}

/// Converts a throwing runtime factory into a structured process startup
/// result. Error classification remains a caller-owned product policy.
public enum HostAgentProcessStartupRunner {
    public static func start<Runtime>(
        startRuntime: () throws -> Runtime,
        classifyError: (Error) -> HostAgentStartupFailure
    ) -> Result<Runtime, HostAgentStartupFailure> {
        do {
            return .success(try startRuntime())
        } catch {
            return .failure(classifyError(error))
        }
    }
}
