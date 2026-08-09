import Foundation

package protocol HostAgentRegistrationRecoveryScheduledTask:
    AnyObject,
    Sendable
{
    func cancel()
}

package enum HostAgentRegistrationRecoveryObservation: Sendable {
    case unavailable
    case snapshot(HostCoreSnapshot)
    case failed
}

package enum HostAgentRegistrationRecoveryConvergence: Equatable, Sendable {
    case pending
    case converged
    case failed
}

package enum HostAgentRegistrationRecoveryOutcome: Equatable, Sendable {
    case converged
    case failed
    case timedOut
}

package enum HostAgentRegistrationRecoveryState: Equatable, Sendable {
    case idle
    case resuming(epoch: UInt64)
    case polling(epoch: UInt64, attempt: UInt64)
    case completing(epoch: UInt64, outcome: HostAgentRegistrationRecoveryOutcome)
    case completed(epoch: UInt64, outcome: HostAgentRegistrationRecoveryOutcome)
    case cancelling
    case cancelled
}

/// Exact-epoch, snapshot-authoritative registration recovery. A successful
/// resume call only starts polling; outward availability may be restored only
/// after a direct HostCore snapshot for the pinned Host reports the same epoch
/// as `running` with registration `ready`.
package final class HostAgentRegistrationRecoveryPollingOwner:
    @unchecked Sendable
{
    package typealias Scheduler = @Sendable (
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> HostAgentRegistrationRecoveryScheduledTask
    package typealias Clock = @Sendable () -> UInt64
    package typealias Resume = @Sendable (_ epoch: UInt64) -> Bool
    package typealias Observe = @Sendable () -> HostAgentRegistrationRecoveryObservation
    package typealias Completion = @Sendable (
        _ epoch: UInt64,
        _ succeeded: Bool
    ) -> Void

    package static let productIntervalMilliseconds: UInt64 = 50
    package static let productMaximumAttempts: UInt64 = 100
    package static let productTimeoutMilliseconds: UInt64 = 5_000

    private let condition = NSCondition()
    private let expectedHostInstanceID: String
    private let intervalMilliseconds: UInt64
    private let maximumAttempts: UInt64
    private let timeoutMilliseconds: UInt64
    private let schedule: Scheduler
    private let nowMilliseconds: Clock
    private let resume: Resume
    private let observe: Observe
    private var state: HostAgentRegistrationRecoveryState = .idle
    private var lastEpoch: UInt64 = 0
    private var generation: UInt64 = 0
    private var scheduledTask: HostAgentRegistrationRecoveryScheduledTask?
    private var completion: Completion?
    private var deadlineMilliseconds: UInt64?
    private var operationInFlight = false
    private var completionInFlight = false

    package static func makeProduct(
        expectedHostInstanceID: String,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-registration-recovery-poll",
            qos: .userInitiated
        ),
        resume: @escaping Resume,
        observe: @escaping Observe
    ) -> HostAgentRegistrationRecoveryPollingOwner {
        HostAgentRegistrationRecoveryPollingOwner(
            expectedHostInstanceID: expectedHostInstanceID,
            intervalMilliseconds: productIntervalMilliseconds,
            maximumAttempts: productMaximumAttempts,
            timeoutMilliseconds: productTimeoutMilliseconds,
            schedule: productScheduler(queue: queue),
            nowMilliseconds: {
                DispatchTime.now().uptimeNanoseconds / 1_000_000
            },
            resume: resume,
            observe: observe
        )
    }

    package static func productScheduler(queue: DispatchQueue) -> Scheduler {
        { delayMilliseconds, action in
            let workItem = DispatchWorkItem(block: action)
            let boundedDelay = Int(min(delayMilliseconds, UInt64(Int.max)))
            queue.asyncAfter(
                deadline: .now() + .milliseconds(boundedDelay),
                execute: workItem
            )
            return HostAgentRegistrationRecoveryDispatchTask(workItem: workItem)
        }
    }

    package init(
        expectedHostInstanceID: String,
        intervalMilliseconds: UInt64,
        maximumAttempts: UInt64,
        timeoutMilliseconds: UInt64,
        schedule: @escaping Scheduler,
        nowMilliseconds: @escaping Clock,
        resume: @escaping Resume,
        observe: @escaping Observe
    ) {
        self.expectedHostInstanceID = expectedHostInstanceID
        self.intervalMilliseconds = intervalMilliseconds
        self.maximumAttempts = maximumAttempts
        self.timeoutMilliseconds = timeoutMilliseconds
        self.schedule = schedule
        self.nowMilliseconds = nowMilliseconds
        self.resume = resume
        self.observe = observe
    }

    deinit {
        cancelAndWait()
    }

    package func stateSnapshot() -> HostAgentRegistrationRecoveryState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    package func start(
        epoch: UInt64,
        completion: @escaping Completion
    ) -> Bool {
        condition.lock()
        guard !expectedHostInstanceID.isEmpty,
              epoch > lastEpoch,
              intervalMilliseconds > 0,
              maximumAttempts > 0,
              timeoutMilliseconds > 0,
              generation < UInt64.max
        else {
            condition.unlock()
            return false
        }
        switch state {
        case .idle, .completed:
            break
        case .resuming, .polling, .completing, .cancelling, .cancelled:
            condition.unlock()
            return false
        }
        generation += 1
        let generation = self.generation
        lastEpoch = epoch
        self.completion = completion
        let now = nowMilliseconds()
        deadlineMilliseconds = now > UInt64.max - timeoutMilliseconds
            ? UInt64.max
            : now + timeoutMilliseconds
        state = .resuming(epoch: epoch)
        operationInFlight = true
        condition.unlock()

        let accepted = resume(epoch)

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard state == .resuming(epoch: epoch),
              self.generation == generation
        else {
            condition.unlock()
            return false
        }
        guard accepted else {
            self.completion = nil
            deadlineMilliseconds = nil
            state = .completed(epoch: epoch, outcome: .failed)
            condition.unlock()
            return false
        }
        state = .polling(epoch: epoch, attempt: 0)
        condition.unlock()

        scheduleNext(epoch: epoch, generation: generation)
        return true
    }

    /// Terminal and idempotent. Product teardown invokes this only outside
    /// resume/poll/completion callbacks so it can drain all in-flight work.
    package func cancelAndWait() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while state == .cancelling {
                condition.wait()
            }
            condition.unlock()
            return
        case .idle, .resuming, .polling, .completing, .completed:
            state = .cancelling
            if generation < UInt64.max { generation += 1 }
            let task = scheduledTask
            scheduledTask = nil
            completion = nil
            deadlineMilliseconds = nil
            condition.unlock()
            task?.cancel()
        }

        condition.lock()
        while operationInFlight || completionInFlight {
            condition.wait()
        }
        state = .cancelled
        condition.broadcast()
        condition.unlock()
    }

    package static func convergence(
        observation: HostAgentRegistrationRecoveryObservation,
        expectedHostInstanceID: String,
        epoch: UInt64
    ) -> HostAgentRegistrationRecoveryConvergence {
        switch observation {
        case .unavailable:
            return .pending
        case .failed:
            return .failed
        case .snapshot(let snapshot):
            guard snapshot.hostInstanceId == expectedHostInstanceID else {
                return .failed
            }
            if snapshot.recoveryEpoch < epoch { return .pending }
            guard snapshot.recoveryEpoch == epoch else { return .failed }
            switch snapshot.recoveryStatus {
            case .resuming:
                return snapshot.registrationStatus == "pending"
                    ? .pending
                    : .failed
            case .running:
                return snapshot.registrationStatus == "ready"
                    ? .converged
                    : .failed
            case .failed, .suspending, .suspended:
                return .failed
            }
        }
    }

    private func scheduleNext(epoch: UInt64, generation: UInt64) {
        condition.lock()
        guard state.isPolling(epoch: epoch),
              self.generation == generation,
              let deadlineMilliseconds
        else {
            condition.unlock()
            return
        }
        let now = nowMilliseconds()
        let remaining = deadlineMilliseconds > now
            ? deadlineMilliseconds - now
            : 0
        let delay = min(intervalMilliseconds, remaining)
        condition.unlock()

        let task = schedule(delay) { [weak self] in
            self?.tick(epoch: epoch, generation: generation)
        }
        condition.lock()
        guard state.isPolling(epoch: epoch),
              self.generation == generation,
              scheduledTask == nil
        else {
            condition.unlock()
            task.cancel()
            return
        }
        scheduledTask = task
        condition.unlock()
    }

    private func tick(epoch: UInt64, generation: UInt64) {
        condition.lock()
        guard case .polling(epoch, let previousAttempt) = state,
              self.generation == generation,
              !operationInFlight,
              previousAttempt < maximumAttempts,
              let deadlineMilliseconds
        else {
            condition.unlock()
            return
        }
        scheduledTask = nil
        if nowMilliseconds() > deadlineMilliseconds {
            let completion = beginCompletionLocked(
                epoch: epoch,
                outcome: .timedOut
            )
            condition.unlock()
            finishCompletion(
                epoch: epoch,
                outcome: .timedOut,
                completion: completion
            )
            return
        }
        let attempt = previousAttempt + 1
        state = .polling(epoch: epoch, attempt: attempt)
        operationInFlight = true
        condition.unlock()

        let convergence = Self.convergence(
            observation: observe(),
            expectedHostInstanceID: expectedHostInstanceID,
            epoch: epoch
        )

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard case .polling(epoch, attempt) = state,
              self.generation == generation
        else {
            condition.unlock()
            return
        }
        let outcome: HostAgentRegistrationRecoveryOutcome?
        switch convergence {
        case .converged:
            outcome = .converged
        case .failed:
            outcome = .failed
        case .pending where attempt >= maximumAttempts
            || nowMilliseconds() >= deadlineMilliseconds:
            outcome = .timedOut
        case .pending:
            outcome = nil
        }
        guard let outcome else {
            condition.unlock()
            scheduleNext(epoch: epoch, generation: generation)
            return
        }
        let completion = beginCompletionLocked(epoch: epoch, outcome: outcome)
        condition.unlock()
        finishCompletion(epoch: epoch, outcome: outcome, completion: completion)
    }

    private func beginCompletionLocked(
        epoch: UInt64,
        outcome: HostAgentRegistrationRecoveryOutcome
    ) -> Completion? {
        state = .completing(epoch: epoch, outcome: outcome)
        completionInFlight = true
        return completion
    }

    private func finishCompletion(
        epoch: UInt64,
        outcome: HostAgentRegistrationRecoveryOutcome,
        completion: Completion?
    ) {
        completion?(epoch, outcome == .converged)

        condition.lock()
        completionInFlight = false
        self.completion = nil
        deadlineMilliseconds = nil
        if state == .completing(epoch: epoch, outcome: outcome) {
            state = .completed(epoch: epoch, outcome: outcome)
        }
        condition.broadcast()
        condition.unlock()
    }
}

private extension HostAgentRegistrationRecoveryState {
    func isPolling(epoch: UInt64) -> Bool {
        guard case .polling(epoch, _) = self else { return false }
        return true
    }
}

private final class HostAgentRegistrationRecoveryDispatchTask:
    HostAgentRegistrationRecoveryScheduledTask,
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
