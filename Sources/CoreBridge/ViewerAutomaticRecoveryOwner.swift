import Foundation

package protocol ViewerAutomaticRecoveryScheduledTask: AnyObject, Sendable {
    func cancel()
}

package enum ViewerAutomaticRecoveryAttemptResult: Equatable, Sendable {
    case started
    case retryableFailure
    case unavailable
}

package enum ViewerAutomaticRecoveryTerminalDecision: Equatable, Sendable {
    case finish
    case recovering
    case ignored
}

package enum ViewerAutomaticRecoveryState: Equatable, Sendable {
    case idle
    case starting(epoch: UInt64)
    case streaming(epoch: UInt64)
    case waiting(epoch: UInt64, generation: UInt64, attempt: UInt64)
    case connecting(epoch: UInt64, generation: UInt64, attempt: UInt64)
    case finished(epoch: UInt64)
    case exhausted(epoch: UInt64)
    case cancelled
}

/// Owns one logical Viewer session across bounded replacement Core clients.
/// A recovery succeeds only when the replacement client reports streaming;
/// merely starting a Core connection never advances the logical session.
package final class ViewerAutomaticRecoveryOwner: @unchecked Sendable {
    package typealias Scheduler = @Sendable (
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> ViewerAutomaticRecoveryScheduledTask
    package typealias Attempt = @Sendable (
        _ sessionEpoch: UInt64,
        _ generation: UInt64,
        _ attempt: UInt64
    ) -> ViewerAutomaticRecoveryAttemptResult
    package typealias Exhausted = @Sendable (_ sessionEpoch: UInt64) -> Void

    package static let productDelaysMilliseconds: [UInt64] = [500, 1_500, 3_000]

    private let condition = NSCondition()
    private let delaysMilliseconds: [UInt64]
    private let schedule: Scheduler
    private let attempt: Attempt
    private let exhausted: Exhausted
    private var state: ViewerAutomaticRecoveryState = .idle
    private var scheduledTask: ViewerAutomaticRecoveryScheduledTask?
    private var operationInFlight = false

    package static func makeProduct(
        queue: DispatchQueue = .main,
        attempt: @escaping Attempt,
        exhausted: @escaping Exhausted
    ) -> ViewerAutomaticRecoveryOwner {
        ViewerAutomaticRecoveryOwner(
            delaysMilliseconds: productDelaysMilliseconds,
            schedule: { delayMilliseconds, action in
                let workItem = DispatchWorkItem(block: action)
                let boundedDelay = Int(min(delayMilliseconds, UInt64(Int.max)))
                queue.asyncAfter(
                    deadline: .now() + .milliseconds(boundedDelay),
                    execute: workItem
                )
                return ViewerAutomaticRecoveryDispatchTask(workItem: workItem)
            },
            attempt: attempt,
            exhausted: exhausted
        )
    }

    package init(
        delaysMilliseconds: [UInt64],
        schedule: @escaping Scheduler,
        attempt: @escaping Attempt,
        exhausted: @escaping Exhausted
    ) {
        self.delaysMilliseconds = delaysMilliseconds
        self.schedule = schedule
        self.attempt = attempt
        self.exhausted = exhausted
    }

    deinit {
        cancelAndWait()
    }

    package func stateSnapshot() -> ViewerAutomaticRecoveryState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    package func begin(sessionEpoch: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard sessionEpoch > 0, !delaysMilliseconds.isEmpty,
              delaysMilliseconds.allSatisfy({ $0 > 0 }), state == .idle
        else { return false }
        state = .starting(epoch: sessionEpoch)
        return true
    }

    /// Returns true only for a real recovery streaming edge, never for the
    /// initial connection or duplicate streaming callbacks.
    @discardableResult
    package func observeStreaming(sessionEpoch: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        switch state {
        case .starting(let epoch) where epoch == sessionEpoch:
            state = .streaming(epoch: epoch)
            return false
        case .connecting(let epoch, _, _) where epoch == sessionEpoch:
            state = .streaming(epoch: epoch)
            return true
        case .idle, .starting, .streaming, .waiting, .connecting,
             .finished, .exhausted, .cancelled:
            return false
        }
    }

    /// A pre-stream terminal edge is final. Once streaming was established,
    /// one terminal edge schedules a bounded recovery window; duplicates while
    /// waiting are ignored and a failed replacement advances to the next try.
    package func observeTerminal(
        sessionEpoch: UInt64
    ) -> ViewerAutomaticRecoveryTerminalDecision {
        condition.lock()
        switch state {
        case .starting(let epoch) where epoch == sessionEpoch:
            state = .finished(epoch: epoch)
            condition.unlock()
            return .finish
        case .streaming(let epoch) where epoch == sessionEpoch:
            scheduleAttemptLocked(epoch: epoch, generation: 1, attemptIndex: 1)
            condition.unlock()
            return .recovering
        case .connecting(let epoch, let generation, let attemptIndex)
            where epoch == sessionEpoch:
            let nextGeneration = generation == UInt64.max ? nil : generation + 1
            let nextAttempt = attemptIndex == UInt64.max ? nil : attemptIndex + 1
            guard let nextGeneration, let nextAttempt,
                  Int(nextAttempt) <= delaysMilliseconds.count
            else {
                state = .exhausted(epoch: epoch)
                condition.unlock()
                exhausted(epoch)
                return .finish
            }
            scheduleAttemptLocked(
                epoch: epoch,
                generation: nextGeneration,
                attemptIndex: nextAttempt
            )
            condition.unlock()
            return .recovering
        case .waiting(let epoch, _, _) where epoch == sessionEpoch:
            condition.unlock()
            return .ignored
        case .idle, .starting, .streaming, .waiting, .connecting,
             .finished, .exhausted, .cancelled:
            condition.unlock()
            return .ignored
        }
    }

    package func cancelAndWait() {
        condition.lock()
        if state == .cancelled {
            while operationInFlight { condition.wait() }
            condition.unlock()
            return
        }
        state = .cancelled
        scheduledTask?.cancel()
        scheduledTask = nil
        while operationInFlight { condition.wait() }
        condition.unlock()
    }

    private func scheduleAttemptLocked(
        epoch: UInt64,
        generation: UInt64,
        attemptIndex: UInt64
    ) {
        let delay = delaysMilliseconds[Int(attemptIndex - 1)]
        state = .waiting(
            epoch: epoch,
            generation: generation,
            attempt: attemptIndex
        )
        scheduledTask = schedule(delay) { [weak self] in
            self?.runAttempt(
                epoch: epoch,
                generation: generation,
                attemptIndex: attemptIndex
            )
        }
    }

    private func runAttempt(
        epoch: UInt64,
        generation: UInt64,
        attemptIndex: UInt64
    ) {
        condition.lock()
        guard state == .waiting(
            epoch: epoch,
            generation: generation,
            attempt: attemptIndex
        ) else {
            condition.unlock()
            return
        }
        scheduledTask = nil
        state = .connecting(
            epoch: epoch,
            generation: generation,
            attempt: attemptIndex
        )
        operationInFlight = true
        condition.unlock()

        let result = attempt(epoch, generation, attemptIndex)

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard state == .connecting(
            epoch: epoch,
            generation: generation,
            attempt: attemptIndex
        ) else {
            condition.unlock()
            return
        }
        switch result {
        case .started:
            condition.unlock()
        case .retryableFailure:
            let decision = advanceAfterFailedAttemptLocked(
                epoch: epoch,
                generation: generation,
                attemptIndex: attemptIndex
            )
            condition.unlock()
            if decision { exhausted(epoch) }
        case .unavailable:
            state = .exhausted(epoch: epoch)
            condition.unlock()
            exhausted(epoch)
        }
    }

    /// Returns true when the bounded attempt list is exhausted.
    private func advanceAfterFailedAttemptLocked(
        epoch: UInt64,
        generation: UInt64,
        attemptIndex: UInt64
    ) -> Bool {
        guard generation < UInt64.max, attemptIndex < UInt64.max else {
            state = .exhausted(epoch: epoch)
            return true
        }
        let nextAttempt = attemptIndex + 1
        guard Int(nextAttempt) <= delaysMilliseconds.count else {
            state = .exhausted(epoch: epoch)
            return true
        }
        scheduleAttemptLocked(
            epoch: epoch,
            generation: generation + 1,
            attemptIndex: nextAttempt
        )
        return false
    }
}

private final class ViewerAutomaticRecoveryDispatchTask:
    ViewerAutomaticRecoveryScheduledTask,
    @unchecked Sendable
{
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}
