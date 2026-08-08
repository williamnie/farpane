import CoreBridge
import Foundation
import VideoPipeline

/// Process-owned one-second media telemetry sampler. The shared gate prevents
/// callback re-entry and makes cancellation wait for an in-flight JSONL write.
final class HostAgentMediaLiveLogPollingOwner: @unchecked Sendable {
    private enum State {
        case idle
        case active
        case cancelling
        case cancelled
    }

    private let condition = NSCondition()
    private let gate = HostAgentSnapshotPollingGate()
    private let coordinator: HostMediaPipelineLiveLogCoordinator
    private let timer: DispatchSourceTimer
    private var state: State = .idle

    init(
        coordinator: HostMediaPipelineLiveLogCoordinator,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.media-live-log",
            qos: .utility
        )
    ) {
        self.coordinator = coordinator
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(100)
        )
        timer.setEventHandler { [weak self] in
            self?.recordOnce()
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

    /// Terminal and idempotent. Concurrent callers join the active drain.
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

        condition.lock()
        state = .cancelled
        condition.broadcast()
        condition.unlock()
    }

    private func recordOnce() {
        guard gate.beginTick() else { return }
        defer { gate.endTick() }
        coordinator.recordPeriodic()
    }
}
