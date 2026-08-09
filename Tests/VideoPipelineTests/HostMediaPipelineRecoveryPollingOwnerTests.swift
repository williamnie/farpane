@testable import VideoPipeline
import Foundation
import XCTest

final class HostMediaPipelineRecoveryPollingOwnerTests: XCTestCase {
  func testProductWindowIsExactlyBoundedAtFiveSeconds() {
    XCTAssertEqual(
      HostMediaPipelineRecoveryPollingOwner.productIntervalMilliseconds,
      50
    )
    XCTAssertEqual(
      HostMediaPipelineRecoveryPollingOwner.productMaximumAttempts,
      100
    )
    XCTAssertEqual(
      HostMediaPipelineRecoveryPollingOwner.productTimeoutMilliseconds,
      5_000
    )
  }

  func testPendingRouteConvergesAndStrictlyNewerEpochCanRestart() {
    let scheduler = RecoveryPollingManualScheduler()
    let convergence = RecoveryConvergenceRecorder([
      .pending,
      .pending,
      .converged,
      .failed,
    ])
    let completions = RecoveryPollingCompletionRecorder()
    let owner = makeOwner(
      scheduler: scheduler,
      maximumAttempts: 5,
      poll: convergence.pollHandler
    )

    XCTAssertTrue(owner.start(epoch: 4, completion: completions.handler))
    XCTAssertFalse(owner.start(epoch: 4, completion: completions.handler))
    XCTAssertEqual(owner.stateSnapshot(), .polling(epoch: 4, attempt: 0))
    XCTAssertEqual(scheduler.delays, [50])

    scheduler.runNext()
    XCTAssertEqual(owner.stateSnapshot(), .polling(epoch: 4, attempt: 1))
    scheduler.runNext()
    XCTAssertEqual(owner.stateSnapshot(), .polling(epoch: 4, attempt: 2))
    scheduler.runNext()
    XCTAssertEqual(
      owner.stateSnapshot(),
      .completed(epoch: 4, outcome: .converged)
    )
    XCTAssertEqual(completions.values, [
      .init(epoch: 4, outcome: .converged),
    ])

    XCTAssertFalse(owner.start(epoch: 3, completion: completions.handler))
    XCTAssertTrue(owner.start(epoch: 5, completion: completions.handler))
    scheduler.runNext()
    XCTAssertEqual(
      owner.stateSnapshot(),
      .completed(epoch: 5, outcome: .failed)
    )
    XCTAssertEqual(completions.values.last, .init(epoch: 5, outcome: .failed))
  }

  func testPendingRouteTimesOutAtExactAttemptBound() {
    let scheduler = RecoveryPollingManualScheduler()
    let convergence = RecoveryConvergenceRecorder([
      .pending,
      .pending,
      .pending,
    ])
    let completions = RecoveryPollingCompletionRecorder()
    let owner = makeOwner(
      scheduler: scheduler,
      maximumAttempts: 3,
      poll: convergence.pollHandler
    )

    XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
    scheduler.runNext()
    scheduler.runNext()
    scheduler.runNext()

    XCTAssertEqual(convergence.pollCount, 3)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(
      owner.stateSnapshot(),
      .completed(epoch: 1, outcome: .timedOut)
    )
    XCTAssertEqual(completions.values, [
      .init(epoch: 1, outcome: .timedOut),
    ])
  }

  func testUnavailableRecoveryFailsClosedWithoutRetry() {
    let scheduler = RecoveryPollingManualScheduler()
    let convergence = RecoveryConvergenceRecorder([.unavailable])
    let completions = RecoveryPollingCompletionRecorder()
    let owner = makeOwner(
      scheduler: scheduler,
      maximumAttempts: 5,
      poll: convergence.pollHandler
    )

    XCTAssertTrue(owner.start(epoch: 7, completion: completions.handler))
    scheduler.runNext()

    XCTAssertEqual(convergence.pollCount, 1)
    XCTAssertEqual(scheduler.pendingCount, 0)
    XCTAssertEqual(
      owner.stateSnapshot(),
      .completed(epoch: 7, outcome: .failed)
    )
  }

  func testTickDelayedPastMonotonicDeadlineTimesOutWithoutPolling() {
    let scheduler = RecoveryPollingManualScheduler()
    let convergence = RecoveryConvergenceRecorder([.converged])
    let completions = RecoveryPollingCompletionRecorder()
    let owner = makeOwner(
      scheduler: scheduler,
      maximumAttempts: 100,
      poll: convergence.pollHandler
    )

    XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
    scheduler.advance(by: 5_001)
    scheduler.runNext()

    XCTAssertEqual(convergence.pollCount, 0)
    XCTAssertEqual(
      owner.stateSnapshot(),
      .completed(epoch: 1, outcome: .timedOut)
    )
    XCTAssertEqual(completions.values, [
      .init(epoch: 1, outcome: .timedOut),
    ])
  }

  func testCancellationRejectsScheduledAndFutureWork() {
    let scheduler = RecoveryPollingManualScheduler()
    let convergence = RecoveryConvergenceRecorder([.converged])
    let completions = RecoveryPollingCompletionRecorder()
    let owner = makeOwner(
      scheduler: scheduler,
      maximumAttempts: 5,
      poll: convergence.pollHandler
    )

    XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
    owner.cancelAndWait()
    scheduler.runNext()

    XCTAssertEqual(owner.stateSnapshot(), .cancelled)
    XCTAssertEqual(convergence.pollCount, 0)
    XCTAssertTrue(completions.values.isEmpty)
    XCTAssertFalse(owner.start(epoch: 2, completion: completions.handler))
    owner.cancelAndWait()
  }

  func testCancellationWaitsForInFlightPollAndSuppressesCompletion() {
    let scheduler = RecoveryPollingManualScheduler()
    let pollEntered = DispatchSemaphore(value: 0)
    let releasePoll = DispatchSemaphore(value: 0)
    let completions = RecoveryPollingCompletionRecorder()
    let owner = makeOwner(
      scheduler: scheduler,
      maximumAttempts: 5,
      poll: {
        pollEntered.signal()
        _ = releasePoll.wait(timeout: .now() + 2)
        return .converged
      }
    )
    let tickReturned = DispatchSemaphore(value: 0)
    let cancelReturned = DispatchSemaphore(value: 0)

    XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
    DispatchQueue.global().async {
      scheduler.runNext()
      tickReturned.signal()
    }
    XCTAssertEqual(pollEntered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async {
      owner.cancelAndWait()
      cancelReturned.signal()
    }
    XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
    releasePoll.signal()
    XCTAssertEqual(tickReturned.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)

    XCTAssertEqual(owner.stateSnapshot(), .cancelled)
    XCTAssertTrue(completions.values.isEmpty)
  }

  private func makeOwner(
    scheduler: RecoveryPollingManualScheduler,
    maximumAttempts: UInt64,
    poll: @escaping HostMediaPipelineRecoveryPollingOwner.Poll
  ) -> HostMediaPipelineRecoveryPollingOwner {
    HostMediaPipelineRecoveryPollingOwner(
      intervalMilliseconds: 50,
      maximumAttempts: maximumAttempts,
      timeoutMilliseconds: 50 * maximumAttempts,
      schedule: scheduler.handler,
      nowMilliseconds: scheduler.clock,
      poll: poll
    )
  }
}

private final class RecoveryPollingManualScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [RecoveryPollingManualTask] = []
  private var recordedDelays: [UInt64] = []
  private var currentMilliseconds: UInt64 = 0

  var delays: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return recordedDelays
  }

  var pendingCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return tasks.count
  }

  var handler: HostMediaPipelineRecoveryPollingOwner.Scheduler {
    { [self] delayMilliseconds, action in
      schedule(delayMilliseconds: delayMilliseconds, action: action)
    }
  }

  var clock: HostMediaPipelineRecoveryPollingOwner.Clock {
    { [self] in
      lock.lock()
      defer { lock.unlock() }
      return currentMilliseconds
    }
  }

  func schedule(
    delayMilliseconds: UInt64,
    action: @escaping @Sendable () -> Void
  ) -> HostMediaPipelineRecoveryScheduledTask {
    let task = RecoveryPollingManualTask(
      delayMilliseconds: delayMilliseconds,
      action: action
    )
    lock.lock()
    recordedDelays.append(delayMilliseconds)
    tasks.append(task)
    lock.unlock()
    return task
  }

  func runNext() {
    lock.lock()
    let task = tasks.isEmpty ? nil : tasks.removeFirst()
    if let task {
      currentMilliseconds += task.delayMilliseconds
    }
    lock.unlock()
    task?.run()
  }

  func advance(by milliseconds: UInt64) {
    lock.lock()
    currentMilliseconds += milliseconds
    lock.unlock()
  }
}

private final class RecoveryPollingManualTask:
  HostMediaPipelineRecoveryScheduledTask,
  @unchecked Sendable
{
  private let lock = NSLock()
  let delayMilliseconds: UInt64
  private let action: @Sendable () -> Void
  private var cancelled = false

  init(
    delayMilliseconds: UInt64,
    action: @escaping @Sendable () -> Void
  ) {
    self.delayMilliseconds = delayMilliseconds
    self.action = action
  }

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func run() {
    lock.lock()
    let shouldRun = !cancelled
    lock.unlock()
    if shouldRun { action() }
  }
}

private final class RecoveryConvergenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var remaining: [HostMediaPipelineRecoveryConvergence]
  private var count = 0

  init(_ values: [HostMediaPipelineRecoveryConvergence]) {
    remaining = values
  }

  var pollCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  var pollHandler: HostMediaPipelineRecoveryPollingOwner.Poll {
    { [self] in poll() }
  }

  func poll() -> HostMediaPipelineRecoveryConvergence {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return remaining.isEmpty ? .pending : remaining.removeFirst()
  }
}

private struct RecoveryPollingCompletion: Equatable {
  let epoch: UInt64
  let outcome: HostMediaPipelineRecoveryPollingOutcome
}

private final class RecoveryPollingCompletionRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RecoveryPollingCompletion] = []

  var values: [RecoveryPollingCompletion] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  var handler: HostMediaPipelineRecoveryPollingOwner.Completion {
    { [self] epoch, outcome in
      record(epoch: epoch, outcome: outcome)
    }
  }

  func record(
    epoch: UInt64,
    outcome: HostMediaPipelineRecoveryPollingOutcome
  ) {
    lock.lock()
    storage.append(.init(epoch: epoch, outcome: outcome))
    lock.unlock()
  }
}
