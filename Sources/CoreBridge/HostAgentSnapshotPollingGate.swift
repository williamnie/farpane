import Foundation

/// Synchronizes one periodic snapshot poll. Cancel marks the gate first and
/// waits for an in-flight tick to finish, so Core teardown cannot overlap it.
public final class HostAgentSnapshotPollingGate: @unchecked Sendable {
    private enum State {
        case idle
        case running
        case cancelled
    }

    private let condition = NSCondition()
    private var state: State = .idle
    private var tickInFlight = false

    public init() {}

    @discardableResult
    public func start() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard case .idle = state else { return false }
        state = .running
        return true
    }

    @discardableResult
    public func beginTick() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard case .running = state, !tickInFlight else { return false }
        tickInFlight = true
        return true
    }

    public func endTick() {
        condition.lock()
        guard tickInFlight else {
            condition.unlock()
            return
        }
        tickInFlight = false
        condition.broadcast()
        condition.unlock()
    }

    /// Must not be called from inside the active tick itself.
    public func cancelAndWait() {
        condition.lock()
        state = .cancelled
        while tickInFlight {
            condition.wait()
        }
        condition.unlock()
    }
}
