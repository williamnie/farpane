@testable import CoreBridge
import Foundation
import XCTest

final class ViewerAutomaticRecoveryOwnerTests: XCTestCase {
    func testRecoveryPolicyRejectsExplicitPeerClose() {
        XCTAssertFalse(ViewerAutomaticRecoveryPolicy.permitsRecovery(after: .init(
            state: .error,
            code: ViewerAutomaticRecoveryPolicy.noRetryTerminalCode,
            message: "connection-no-retry"
        )))
        XCTAssertFalse(ViewerAutomaticRecoveryPolicy.permitsRecovery(after: .init(
            state: .disconnected,
            code: ViewerAutomaticRecoveryPolicy.noRetryTerminalCode,
            message: "disconnected-no-retry"
        )))
    }

    func testRecoveryPolicyKeepsTransientRecovery() {
        XCTAssertTrue(ViewerAutomaticRecoveryPolicy.permitsRecovery(after: .init(
            state: .error,
            code: 10,
            message: "connection-timeout"
        )))
        XCTAssertTrue(ViewerAutomaticRecoveryPolicy.permitsRecovery(after: .init(
            state: .disconnected,
            code: 0,
            message: "disconnected"
        )))
        XCTAssertFalse(ViewerAutomaticRecoveryPolicy.permitsRecovery(after: .init(
            state: .streaming,
            code: 0,
            message: "streaming"
        )))
    }

    func testProductBackoffIsBounded() {
        XCTAssertEqual(
            ViewerAutomaticRecoveryOwner.productDelaysMilliseconds,
            [500, 1_500, 3_000]
        )
    }

    func testInitialStreamingIsNotRecoveryButReplacementStreamingIs() {
        let scheduler = ViewerRecoveryManualScheduler()
        let attempts = ViewerRecoveryAttemptRecorder([.started])
        let exhausted = ViewerRecoveryExhaustedRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            attempts: attempts,
            exhausted: exhausted
        )

        XCTAssertTrue(owner.begin(sessionEpoch: 7))
        XCTAssertFalse(owner.observeStreaming(sessionEpoch: 7))
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 7), .recovering)
        XCTAssertEqual(scheduler.delays, [10])
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 7), .ignored)

        scheduler.runNext()
        XCTAssertEqual(attempts.values, [.init(epoch: 7, generation: 1, attempt: 1)])
        XCTAssertEqual(
            owner.stateSnapshot(),
            .connecting(epoch: 7, generation: 1, attempt: 1)
        )
        XCTAssertTrue(owner.observeStreaming(sessionEpoch: 7))
        XCTAssertEqual(owner.stateSnapshot(), .streaming(epoch: 7))
        XCTAssertTrue(exhausted.epochs.isEmpty)
    }

    func testPrestreamTerminalAndStaleEpochFailClosed() {
        let scheduler = ViewerRecoveryManualScheduler()
        let attempts = ViewerRecoveryAttemptRecorder([.started])
        let exhausted = ViewerRecoveryExhaustedRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            attempts: attempts,
            exhausted: exhausted
        )

        XCTAssertFalse(owner.begin(sessionEpoch: 0))
        XCTAssertTrue(owner.begin(sessionEpoch: 3))
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 4), .ignored)
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 3), .finish)
        XCTAssertEqual(owner.stateSnapshot(), .finished(epoch: 3))
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(attempts.values.isEmpty)
    }

    func testRetryableFailuresExhaustExactAttemptList() {
        let scheduler = ViewerRecoveryManualScheduler()
        let attempts = ViewerRecoveryAttemptRecorder([
            .retryableFailure, .retryableFailure, .retryableFailure,
        ])
        let exhausted = ViewerRecoveryExhaustedRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            attempts: attempts,
            exhausted: exhausted
        )

        XCTAssertTrue(owner.begin(sessionEpoch: 1))
        XCTAssertFalse(owner.observeStreaming(sessionEpoch: 1))
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 1), .recovering)
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()

        XCTAssertEqual(scheduler.delays, [10, 20, 30])
        XCTAssertEqual(attempts.values.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(owner.stateSnapshot(), .exhausted(epoch: 1))
        XCTAssertEqual(exhausted.epochs, [1])
    }

    func testStartedReplacementTerminalAdvancesToNextAttempt() {
        let scheduler = ViewerRecoveryManualScheduler()
        let attempts = ViewerRecoveryAttemptRecorder([.started, .started])
        let exhausted = ViewerRecoveryExhaustedRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            attempts: attempts,
            exhausted: exhausted
        )

        XCTAssertTrue(owner.begin(sessionEpoch: 5))
        XCTAssertFalse(owner.observeStreaming(sessionEpoch: 5))
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 5), .recovering)
        scheduler.runNext()
        XCTAssertEqual(
            owner.observeTerminal(sessionEpoch: 5),
            .recovering
        )
        XCTAssertEqual(scheduler.delays, [10, 20])
        scheduler.runNext()

        XCTAssertEqual(attempts.values.map(\.attempt), [1, 2])
        XCTAssertEqual(
            owner.stateSnapshot(),
            .connecting(epoch: 5, generation: 2, attempt: 2)
        )
        XCTAssertTrue(owner.observeStreaming(sessionEpoch: 5))
        XCTAssertEqual(owner.stateSnapshot(), .streaming(epoch: 5))
        XCTAssertTrue(exhausted.epochs.isEmpty)
    }

    func testUnavailableCredentialExhaustsWithoutFurtherRetry() {
        let scheduler = ViewerRecoveryManualScheduler()
        let attempts = ViewerRecoveryAttemptRecorder([.unavailable])
        let exhausted = ViewerRecoveryExhaustedRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            attempts: attempts,
            exhausted: exhausted
        )

        XCTAssertTrue(owner.begin(sessionEpoch: 9))
        XCTAssertFalse(owner.observeStreaming(sessionEpoch: 9))
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 9), .recovering)
        scheduler.runNext()

        XCTAssertEqual(scheduler.delays, [10])
        XCTAssertEqual(exhausted.epochs, [9])
        XCTAssertEqual(owner.stateSnapshot(), .exhausted(epoch: 9))
    }

    func testCancellationSuppressesScheduledAttempt() {
        let scheduler = ViewerRecoveryManualScheduler()
        let attempts = ViewerRecoveryAttemptRecorder([.started])
        let exhausted = ViewerRecoveryExhaustedRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            attempts: attempts,
            exhausted: exhausted
        )

        XCTAssertTrue(owner.begin(sessionEpoch: 2))
        XCTAssertFalse(owner.observeStreaming(sessionEpoch: 2))
        XCTAssertEqual(owner.observeTerminal(sessionEpoch: 2), .recovering)
        owner.cancelAndWait()
        scheduler.runNext()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertTrue(attempts.values.isEmpty)
        XCTAssertTrue(exhausted.epochs.isEmpty)
    }

    private func makeOwner(
        scheduler: ViewerRecoveryManualScheduler,
        attempts: ViewerRecoveryAttemptRecorder,
        exhausted: ViewerRecoveryExhaustedRecorder
    ) -> ViewerAutomaticRecoveryOwner {
        ViewerAutomaticRecoveryOwner(
            delaysMilliseconds: [10, 20, 30],
            schedule: scheduler.schedule,
            attempt: attempts.handler,
            exhausted: exhausted.handler
        )
    }
}

private final class ViewerRecoveryManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Entry] = []
    private(set) var delays: [UInt64] = []

    var pendingCount: Int { lock.withLock { entries.count } }

    lazy var schedule: ViewerAutomaticRecoveryOwner.Scheduler = {
        [weak self] delay, action in
        guard let self else { return ViewerRecoveryManualTask {} }
        let task = ViewerRecoveryManualTask(action)
        self.lock.withLock {
            self.delays.append(delay)
            self.entries.append(.init(task: task))
        }
        return task
    }

    func runNext() {
        let entry = lock.withLock { entries.isEmpty ? nil : entries.removeFirst() }
        entry?.task.run()
    }

    private struct Entry {
        let task: ViewerRecoveryManualTask
    }
}

private final class ViewerRecoveryManualTask:
    ViewerAutomaticRecoveryScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    func run() {
        let action = lock.withLock {
            defer { self.action = nil }
            return self.action
        }
        action?()
    }

    func cancel() {
        lock.withLock { action = nil }
    }
}

private final class ViewerRecoveryAttemptRecorder: @unchecked Sendable {
    struct Value: Equatable {
        let epoch: UInt64
        let generation: UInt64
        let attempt: UInt64
    }

    private let lock = NSLock()
    private var results: [ViewerAutomaticRecoveryAttemptResult]
    private(set) var values: [Value] = []

    init(_ results: [ViewerAutomaticRecoveryAttemptResult]) {
        self.results = results
    }

    lazy var handler: ViewerAutomaticRecoveryOwner.Attempt = {
        [weak self] epoch, generation, attempt in
        guard let self else { return .unavailable }
        return self.lock.withLock {
            self.values.append(.init(epoch: epoch, generation: generation, attempt: attempt))
            return self.results.isEmpty ? .unavailable : self.results.removeFirst()
        }
    }
}

private final class ViewerRecoveryExhaustedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var epochs: [UInt64] = []

    lazy var handler: ViewerAutomaticRecoveryOwner.Exhausted = {
        [weak self] epoch in
        self?.lock.withLock { self?.epochs.append(epoch) }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
