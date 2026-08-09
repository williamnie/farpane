import Foundation

package protocol HostMediaPipelineRecoveryScheduledTask:
  AnyObject,
  Sendable
{
  func cancel()
}

package enum HostMediaPipelineRecoveryPollingOutcome: Equatable, Sendable {
  case converged
  case failed
  case timedOut
}

package enum HostMediaPipelineRecoveryPollingState: Equatable, Sendable {
  case idle
  case polling(epoch: UInt64, attempt: UInt64)
  case completing(
    epoch: UInt64,
    outcome: HostMediaPipelineRecoveryPollingOutcome
  )
  case completed(
    epoch: UInt64,
    outcome: HostMediaPipelineRecoveryPollingOutcome
  )
  case cancelling
  case cancelled
}

/// Process-owned, epoch-bound polling around asynchronous post-wake media
/// reconstruction. Product defaults poll every 50 ms for at most five seconds.
/// Cancellation drains an in-flight poll or terminal callback before returning.
package final class HostMediaPipelineRecoveryPollingOwner:
  @unchecked Sendable
{
  package typealias Scheduler = @Sendable (
    _ delayMilliseconds: UInt64,
    _ action: @escaping @Sendable () -> Void
  ) -> HostMediaPipelineRecoveryScheduledTask
  package typealias Poll = @Sendable ()
    -> HostMediaPipelineRecoveryConvergence
  package typealias Clock = @Sendable () -> UInt64
  package typealias Completion = @Sendable (
    _ epoch: UInt64,
    _ outcome: HostMediaPipelineRecoveryPollingOutcome
  ) -> Void

  package static let productIntervalMilliseconds: UInt64 = 50
  package static let productMaximumAttempts: UInt64 = 100
  package static let productTimeoutMilliseconds: UInt64 = 5_000

  private let condition = NSCondition()
  private let schedule: Scheduler
  private let poll: Poll
  private let nowMilliseconds: Clock
  private let intervalMilliseconds: UInt64
  private let maximumAttempts: UInt64
  private let timeoutMilliseconds: UInt64
  private var state: HostMediaPipelineRecoveryPollingState = .idle
  private var lastEpoch: UInt64 = 0
  private var generation: UInt64 = 0
  private var scheduledTask: HostMediaPipelineRecoveryScheduledTask?
  private var completion: Completion?
  private var deadlineMilliseconds: UInt64?
  private var pollInFlight = false
  private var completionInFlight = false

  package static func makeProduct(
    queue: DispatchQueue = DispatchQueue(
      label: "io.farpane.host-media-recovery-poll",
      qos: .userInitiated
    ),
    poll: @escaping Poll
  ) -> HostMediaPipelineRecoveryPollingOwner {
    HostMediaPipelineRecoveryPollingOwner(
      intervalMilliseconds: productIntervalMilliseconds,
      maximumAttempts: productMaximumAttempts,
      timeoutMilliseconds: productTimeoutMilliseconds,
      schedule: productScheduler(queue: queue),
      nowMilliseconds: {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
      },
      poll: poll
    )
  }

  package static func productScheduler(
    queue: DispatchQueue
  ) -> Scheduler {
    { delayMilliseconds, action in
      let workItem = DispatchWorkItem(block: action)
      let boundedDelay = Int(min(delayMilliseconds, UInt64(Int.max)))
      queue.asyncAfter(
        deadline: .now() + .milliseconds(boundedDelay),
        execute: workItem
      )
      return HostMediaPipelineRecoveryDispatchTask(workItem: workItem)
    }
  }

  package init(
    intervalMilliseconds: UInt64,
    maximumAttempts: UInt64,
    timeoutMilliseconds: UInt64,
    schedule: @escaping Scheduler,
    nowMilliseconds: @escaping Clock,
    poll: @escaping Poll
  ) {
    self.intervalMilliseconds = intervalMilliseconds
    self.maximumAttempts = maximumAttempts
    self.timeoutMilliseconds = timeoutMilliseconds
    self.schedule = schedule
    self.nowMilliseconds = nowMilliseconds
    self.poll = poll
  }

  deinit {
    cancelAndWait()
  }

  package func stateSnapshot() -> HostMediaPipelineRecoveryPollingState {
    condition.lock()
    defer { condition.unlock() }
    return state
  }

  /// Starts one recovery epoch. Completed owners may accept a strictly newer
  /// epoch; duplicate, rollback, invalid timing and exhausted generations fail
  /// without scheduling work.
  @discardableResult
  package func start(
    epoch: UInt64,
    completion: @escaping Completion
  ) -> Bool {
    condition.lock()
    guard epoch > lastEpoch,
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
    case .polling, .completing, .cancelling, .cancelled:
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
    state = .polling(epoch: epoch, attempt: 0)
    condition.unlock()

    scheduleNext(epoch: epoch, generation: generation)
    return true
  }

  /// Terminal and idempotent. Do not invoke synchronously from the completion
  /// callback itself; external teardown waits for that callback to return.
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
    case .idle, .polling, .completing, .completed:
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
    while pollInFlight || completionInFlight {
      condition.wait()
    }
    state = .cancelled
    condition.broadcast()
    condition.unlock()
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
          !pollInFlight,
          previousAttempt < maximumAttempts,
          let deadlineMilliseconds
    else {
      condition.unlock()
      return
    }
    scheduledTask = nil
    if nowMilliseconds() > deadlineMilliseconds {
      let outcome = HostMediaPipelineRecoveryPollingOutcome.timedOut
      let completion = beginCompletionLocked(epoch: epoch, outcome: outcome)
      condition.unlock()
      finishCompletion(epoch: epoch, outcome: outcome, completion: completion)
      return
    }
    let attempt = previousAttempt + 1
    state = .polling(epoch: epoch, attempt: attempt)
    pollInFlight = true
    condition.unlock()

    let convergence = poll()

    condition.lock()
    pollInFlight = false
    condition.broadcast()
    guard case .polling(epoch, attempt) = state,
          self.generation == generation
    else {
      condition.unlock()
      return
    }
    let outcome: HostMediaPipelineRecoveryPollingOutcome?
    switch convergence {
    case .converged:
      outcome = .converged
    case .failed, .unavailable:
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
    outcome: HostMediaPipelineRecoveryPollingOutcome
  ) -> Completion? {
    state = .completing(epoch: epoch, outcome: outcome)
    completionInFlight = true
    return completion
  }

  private func finishCompletion(
    epoch: UInt64,
    outcome: HostMediaPipelineRecoveryPollingOutcome,
    completion: Completion?
  ) {
    completion?(epoch, outcome)

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

private extension HostMediaPipelineRecoveryPollingState {
  func isPolling(epoch: UInt64) -> Bool {
    guard case .polling(epoch, _) = self else { return false }
    return true
  }
}

private final class HostMediaPipelineRecoveryDispatchTask:
  HostMediaPipelineRecoveryScheduledTask,
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
