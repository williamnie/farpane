import CoreBridge
import Foundation

/// Process-owned 500 ms registration poll. The timer callback is non-reentrant
/// and synchronous cancellation waits for any active snapshot copy to finish.
final class HostAgentSnapshotPollingOwner: @unchecked Sendable {
    private enum State {
        case idle
        case active
        case cancelling
        case cancelled
    }

    private let condition = NSCondition()
    private let gate = HostAgentSnapshotPollingGate()
    private let snapshotCoordinator: HostAgentSnapshotRefreshCoordinator
    private let timer: DispatchSourceTimer
    private var state: State = .idle

    init(
        snapshotCoordinator: HostAgentSnapshotRefreshCoordinator,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.snapshot-poll",
            qos: .utility
        )
    ) {
        self.snapshotCoordinator = snapshotCoordinator
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(
            deadline: .now() + .milliseconds(500),
            repeating: .milliseconds(500),
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            self?.pollOnce()
        }
    }

    deinit {
        cancel()
    }

    @discardableResult
    func start() -> Bool {
        condition.lock()
        guard case .idle = state, gate.start() else {
            condition.unlock()
            return false
        }
        state = .active
        timer.activate()
        condition.unlock()
        return true
    }

    /// Idempotent for all callers. Concurrent cancel callers wait for the one
    /// active cancellation, and that cancellation waits for an in-flight poll.
    func cancel() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while case .cancelling = state {
                condition.wait()
            }
            condition.unlock()
            return
        case .idle:
            state = .cancelling
            timer.setEventHandler {}
            timer.activate()
            timer.cancel()
        case .active:
            state = .cancelling
            timer.setEventHandler {}
            timer.cancel()
        }
        condition.unlock()

        gate.cancelAndWait()
        snapshotCoordinator.cancelAndWait()

        condition.lock()
        state = .cancelled
        condition.broadcast()
        condition.unlock()
    }

    private func pollOnce() {
        guard gate.beginTick() else { return }
        defer { gate.endTick() }
        snapshotCoordinator.requestPoll()
    }
}
