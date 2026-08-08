import Foundation

/// Sanitized result published after the single runtime stop attempt finishes.
public struct HostAgentProcessTerminationOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case stopped
        case stopFailed
    }

    public let reason: HostStopReason
    public let status: Status

    public init(reason: HostStopReason, status: Status) {
        self.reason = reason
        self.status = status
    }
}

/// Strongly owns a process runtime until the first termination request has
/// completed its one stop attempt. Duplicate requests never block or stop the
/// runtime again; waiters observe only the sanitized terminal outcome.
public final class HostAgentProcessLifetimeGate<Runtime: AnyObject>:
    @unchecked Sendable
{
    private enum State {
        case running(Runtime)
        case stopping
        case terminated(HostAgentProcessTerminationOutcome)
    }

    private let condition = NSCondition()
    private let stopRuntime: (Runtime, HostStopReason) throws -> Void
    private var state: State

    public init(
        runtime: Runtime,
        stopRuntime: @escaping (Runtime, HostStopReason) throws -> Void
    ) {
        self.state = .running(runtime)
        self.stopRuntime = stopRuntime
    }

    deinit {
        _ = requestTermination(reason: .appExit)
    }

    /// Returns true only for the request that claimed the runtime. The stop
    /// attempt is synchronous for that caller; duplicates return immediately.
    @discardableResult
    public func requestTermination(reason: HostStopReason) -> Bool {
        condition.lock()
        guard case .running(let runtime) = state else {
            condition.unlock()
            return false
        }
        state = .stopping
        condition.unlock()

        let status: HostAgentProcessTerminationOutcome.Status
        do {
            try stopRuntime(runtime, reason)
            status = .stopped
        } catch {
            status = .stopFailed
        }
        let outcome = HostAgentProcessTerminationOutcome(
            reason: reason,
            status: status
        )

        condition.lock()
        state = .terminated(outcome)
        condition.broadcast()
        condition.unlock()
        return true
    }

    /// Blocks without polling until the first stop attempt has published its
    /// terminal outcome. Calling this before any request intentionally waits.
    public func waitUntilTerminated() -> HostAgentProcessTerminationOutcome {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if case .terminated(let outcome) = state {
                return outcome
            }
            condition.wait()
        }
    }
}
