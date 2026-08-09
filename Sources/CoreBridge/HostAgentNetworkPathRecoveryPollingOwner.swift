import Foundation

package protocol HostAgentNetworkPathRecoveryScheduledTask:
    AnyObject,
    Sendable
{
    func cancel()
}

package enum HostAgentNetworkPathRecoveryObservation: Sendable {
    case unavailable
    case snapshot(HostCoreSnapshot)
    case failed
}

package enum HostAgentNetworkPathRecoveryConvergence: Equatable, Sendable {
    case pending
    case converged
    case failed
}

package enum HostAgentNetworkPathRecoveryOutcome: Equatable, Sendable {
    case converged
    case failed
    case timedOut
}

package enum HostAgentNetworkPathRecoveryPollingState: Equatable, Sendable {
    case idle
    case baselining(pathGeneration: UInt64)
    case restarting(pathGeneration: UInt64, recoveryEpoch: UInt64)
    case polling(pathGeneration: UInt64, recoveryEpoch: UInt64, attempt: UInt64)
    case completing(pathGeneration: UInt64, outcome: HostAgentNetworkPathRecoveryOutcome)
    case completed(pathGeneration: UInt64, outcome: HostAgentNetworkPathRecoveryOutcome)
    case cancelling
    case cancelled
}

/// Exact-generation network registration recovery with authoritative snapshot
/// convergence. A baseline pins both Host identity and sleep recovery epoch;
/// a later sleep/wake cycle cannot be mistaken for this network restart.
package final class HostAgentNetworkPathRecoveryPollingOwner:
    @unchecked Sendable
{
    package typealias Scheduler = @Sendable (
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> HostAgentNetworkPathRecoveryScheduledTask
    package typealias Clock = @Sendable () -> UInt64
    package typealias Recover = @Sendable (_ pathGeneration: UInt64) -> Bool
    package typealias Observe = @Sendable () -> HostAgentNetworkPathRecoveryObservation
    package typealias Completion = @Sendable (
        _ pathGeneration: UInt64,
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
    private let recover: Recover
    private let observe: Observe
    private var state: HostAgentNetworkPathRecoveryPollingState = .idle
    private var lastPathGeneration: UInt64 = 0
    private var ownerGeneration: UInt64 = 0
    private var scheduledTask: HostAgentNetworkPathRecoveryScheduledTask?
    private var completion: Completion?
    private var deadlineMilliseconds: UInt64?
    private var operationInFlight = false
    private var completionInFlight = false

    package static func makeProduct(
        expectedHostInstanceID: String,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-network-path-recovery-poll",
            qos: .userInitiated
        ),
        recover: @escaping Recover,
        observe: @escaping Observe
    ) -> HostAgentNetworkPathRecoveryPollingOwner {
        HostAgentNetworkPathRecoveryPollingOwner(
            expectedHostInstanceID: expectedHostInstanceID,
            intervalMilliseconds: productIntervalMilliseconds,
            maximumAttempts: productMaximumAttempts,
            timeoutMilliseconds: productTimeoutMilliseconds,
            schedule: productScheduler(queue: queue),
            nowMilliseconds: {
                DispatchTime.now().uptimeNanoseconds / 1_000_000
            },
            recover: recover,
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
            return HostAgentNetworkPathRecoveryDispatchTask(workItem: workItem)
        }
    }

    package init(
        expectedHostInstanceID: String,
        intervalMilliseconds: UInt64,
        maximumAttempts: UInt64,
        timeoutMilliseconds: UInt64,
        schedule: @escaping Scheduler,
        nowMilliseconds: @escaping Clock,
        recover: @escaping Recover,
        observe: @escaping Observe
    ) {
        self.expectedHostInstanceID = expectedHostInstanceID
        self.intervalMilliseconds = intervalMilliseconds
        self.maximumAttempts = maximumAttempts
        self.timeoutMilliseconds = timeoutMilliseconds
        self.schedule = schedule
        self.nowMilliseconds = nowMilliseconds
        self.recover = recover
        self.observe = observe
    }

    deinit {
        cancelAndWait()
    }

    package func stateSnapshot() -> HostAgentNetworkPathRecoveryPollingState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    package func start(
        pathGeneration: UInt64,
        completion: @escaping Completion
    ) -> Bool {
        condition.lock()
        guard !expectedHostInstanceID.isEmpty,
              isExactNextPathGeneration(pathGeneration),
              intervalMilliseconds > 0,
              maximumAttempts > 0,
              timeoutMilliseconds > 0,
              ownerGeneration < UInt64.max
        else {
            condition.unlock()
            return false
        }
        switch state {
        case .idle, .completed:
            break
        case .baselining, .restarting, .polling, .completing,
             .cancelling, .cancelled:
            condition.unlock()
            return false
        }
        ownerGeneration += 1
        let ownerGeneration = self.ownerGeneration
        lastPathGeneration = pathGeneration
        self.completion = completion
        state = .baselining(pathGeneration: pathGeneration)
        operationInFlight = true
        condition.unlock()

        let baseline = observe()

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard state == .baselining(pathGeneration: pathGeneration),
              self.ownerGeneration == ownerGeneration
        else {
            condition.unlock()
            return false
        }
        guard let recoveryEpoch = Self.baselineRecoveryEpoch(
            observation: baseline,
            expectedHostInstanceID: expectedHostInstanceID
        ) else {
            rejectStartLocked(pathGeneration: pathGeneration)
            condition.unlock()
            return false
        }
        state = .restarting(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch
        )
        operationInFlight = true
        condition.unlock()

        let accepted = recover(pathGeneration)

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard state == .restarting(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch
        ), self.ownerGeneration == ownerGeneration
        else {
            condition.unlock()
            return false
        }
        guard accepted else {
            rejectStartLocked(pathGeneration: pathGeneration)
            condition.unlock()
            return false
        }
        let now = nowMilliseconds()
        deadlineMilliseconds = now > UInt64.max - timeoutMilliseconds
            ? UInt64.max
            : now + timeoutMilliseconds
        state = .polling(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch,
            attempt: 0
        )
        condition.unlock()

        scheduleNext(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch,
            ownerGeneration: ownerGeneration
        )
        return true
    }

    /// Terminal and idempotent. Teardown invokes this outside operation and
    /// completion callbacks so all accepted work can be drained safely.
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
        case .idle, .baselining, .restarting, .polling, .completing, .completed:
            state = .cancelling
            if ownerGeneration < UInt64.max { ownerGeneration += 1 }
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

    package static func baselineRecoveryEpoch(
        observation: HostAgentNetworkPathRecoveryObservation,
        expectedHostInstanceID: String
    ) -> UInt64? {
        guard case .snapshot(let snapshot) = observation,
              snapshot.hostInstanceId == expectedHostInstanceID,
              snapshot.recoveryStatus == .running,
              (snapshot.hostState == "starting" || snapshot.hostState == "ready")
        else {
            return nil
        }
        switch (snapshot.hostState, snapshot.registrationStatus) {
        case ("starting", "pending"), ("ready", "ready"):
            return snapshot.recoveryEpoch
        default:
            return nil
        }
    }

    package static func convergence(
        observation: HostAgentNetworkPathRecoveryObservation,
        expectedHostInstanceID: String,
        recoveryEpoch: UInt64
    ) -> HostAgentNetworkPathRecoveryConvergence {
        switch observation {
        case .unavailable:
            return .pending
        case .failed:
            return .failed
        case .snapshot(let snapshot):
            guard snapshot.hostInstanceId == expectedHostInstanceID,
                  snapshot.recoveryEpoch == recoveryEpoch,
                  snapshot.recoveryStatus == .running
            else {
                return .failed
            }
            switch (snapshot.hostState, snapshot.registrationStatus) {
            case ("starting", "pending"):
                return .pending
            case ("ready", "ready"):
                return .converged
            default:
                return .failed
            }
        }
    }

    private func isExactNextPathGeneration(_ requested: UInt64) -> Bool {
        requested != 0
            && lastPathGeneration.checkedAdding(1) == requested
    }

    private func rejectStartLocked(pathGeneration: UInt64) {
        completion = nil
        deadlineMilliseconds = nil
        state = .completed(pathGeneration: pathGeneration, outcome: .failed)
    }

    private func scheduleNext(
        pathGeneration: UInt64,
        recoveryEpoch: UInt64,
        ownerGeneration: UInt64
    ) {
        condition.lock()
        guard state.isPolling(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch
        ), self.ownerGeneration == ownerGeneration,
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
            self?.tick(
                pathGeneration: pathGeneration,
                recoveryEpoch: recoveryEpoch,
                ownerGeneration: ownerGeneration
            )
        }
        condition.lock()
        guard state.isPolling(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch
        ), self.ownerGeneration == ownerGeneration,
           scheduledTask == nil
        else {
            condition.unlock()
            task.cancel()
            return
        }
        scheduledTask = task
        condition.unlock()
    }

    private func tick(
        pathGeneration: UInt64,
        recoveryEpoch: UInt64,
        ownerGeneration: UInt64
    ) {
        condition.lock()
        guard case .polling(
            pathGeneration,
            recoveryEpoch,
            let previousAttempt
        ) = state,
        self.ownerGeneration == ownerGeneration,
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
                pathGeneration: pathGeneration,
                outcome: .timedOut
            )
            condition.unlock()
            finishCompletion(
                pathGeneration: pathGeneration,
                outcome: .timedOut,
                completion: completion
            )
            return
        }
        let attempt = previousAttempt + 1
        state = .polling(
            pathGeneration: pathGeneration,
            recoveryEpoch: recoveryEpoch,
            attempt: attempt
        )
        operationInFlight = true
        condition.unlock()

        let convergence = Self.convergence(
            observation: observe(),
            expectedHostInstanceID: expectedHostInstanceID,
            recoveryEpoch: recoveryEpoch
        )

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard case .polling(pathGeneration, recoveryEpoch, attempt) = state,
              self.ownerGeneration == ownerGeneration
        else {
            condition.unlock()
            return
        }
        let outcome: HostAgentNetworkPathRecoveryOutcome?
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
            scheduleNext(
                pathGeneration: pathGeneration,
                recoveryEpoch: recoveryEpoch,
                ownerGeneration: ownerGeneration
            )
            return
        }
        let completion = beginCompletionLocked(
            pathGeneration: pathGeneration,
            outcome: outcome
        )
        condition.unlock()
        finishCompletion(
            pathGeneration: pathGeneration,
            outcome: outcome,
            completion: completion
        )
    }

    private func beginCompletionLocked(
        pathGeneration: UInt64,
        outcome: HostAgentNetworkPathRecoveryOutcome
    ) -> Completion? {
        state = .completing(pathGeneration: pathGeneration, outcome: outcome)
        completionInFlight = true
        return completion
    }

    private func finishCompletion(
        pathGeneration: UInt64,
        outcome: HostAgentNetworkPathRecoveryOutcome,
        completion: Completion?
    ) {
        completion?(pathGeneration, outcome == .converged)

        condition.lock()
        completionInFlight = false
        self.completion = nil
        deadlineMilliseconds = nil
        if state == .completing(
            pathGeneration: pathGeneration,
            outcome: outcome
        ) {
            state = .completed(
                pathGeneration: pathGeneration,
                outcome: outcome
            )
        }
        condition.broadcast()
        condition.unlock()
    }
}

private extension HostAgentNetworkPathRecoveryPollingState {
    func isPolling(pathGeneration: UInt64, recoveryEpoch: UInt64) -> Bool {
        guard case .polling(pathGeneration, recoveryEpoch, _) = self else {
            return false
        }
        return true
    }
}

private extension UInt64 {
    func checkedAdding(_ value: UInt64) -> UInt64? {
        let (result, overflow) = addingReportingOverflow(value)
        return overflow ? nil : result
    }
}

private final class HostAgentNetworkPathRecoveryDispatchTask:
    HostAgentNetworkPathRecoveryScheduledTask,
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
