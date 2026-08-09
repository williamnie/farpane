@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentNetworkPathRecoveryPollingOwnerTests: XCTestCase {
    func testProductWindowIsExactlyBoundedAtFiveSeconds() {
        XCTAssertEqual(
            HostAgentNetworkPathRecoveryPollingOwner.productIntervalMilliseconds,
            50
        )
        XCTAssertEqual(
            HostAgentNetworkPathRecoveryPollingOwner.productMaximumAttempts,
            100
        )
        XCTAssertEqual(
            HostAgentNetworkPathRecoveryPollingOwner.productTimeoutMilliseconds,
            5_000
        )
    }

    func testBaselinePinsHostAndSleepEpochUntilRunningReady() throws {
        let scheduler = NetworkRecoveryManualScheduler()
        let recover = NetworkRecoveryCallRecorder(accepted: true)
        let observations = NetworkRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 4, hostState: "ready", registration: "ready")),
            .snapshot(try snapshot(epoch: 4, hostState: "starting", registration: "pending")),
            .snapshot(try snapshot(epoch: 4, hostState: "ready", registration: "ready")),
        ])
        let completions = NetworkRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            recover: recover.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(
            pathGeneration: 1,
            completion: completions.handler
        ))
        XCTAssertEqual(recover.generations, [1])
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .polling(pathGeneration: 1, recoveryEpoch: 4, attempt: 0)
        )
        scheduler.runNext()
        XCTAssertEqual(
            owner.stateSnapshot(),
            .polling(pathGeneration: 1, recoveryEpoch: 4, attempt: 1)
        )
        scheduler.runNext()

        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(pathGeneration: 1, outcome: .converged)
        )
        XCTAssertEqual(
            completions.values,
            [.init(pathGeneration: 1, succeeded: true)]
        )
        XCTAssertEqual(recover.generations, [1])
    }

    func testBaselineMustBeCoherentBeforeRestartIsCalled() throws {
        let invalidBaselines: [HostAgentNetworkPathRecoveryObservation] = [
            .unavailable,
            .failed,
            .snapshot(try snapshot(
                hostInstanceID: "foreign-host",
                epoch: 3,
                hostState: "ready",
                registration: "ready"
            )),
            .snapshot(try snapshot(
                epoch: 3,
                status: .suspending,
                hostState: "starting",
                registration: "suspending"
            )),
            .snapshot(try snapshot(
                epoch: 3,
                hostState: "starting",
                registration: "ready"
            )),
        ]

        for baseline in invalidBaselines {
            let scheduler = NetworkRecoveryManualScheduler()
            let recover = NetworkRecoveryCallRecorder(accepted: true)
            let observations = NetworkRecoveryObservationRecorder([baseline])
            let completions = NetworkRecoveryCompletionRecorder()
            let owner = makeOwner(
                scheduler: scheduler,
                recover: recover.handler,
                observe: observations.handler
            )
            XCTAssertFalse(owner.start(
                pathGeneration: 1,
                completion: completions.handler
            ))
            XCTAssertEqual(
                owner.stateSnapshot(),
                .completed(pathGeneration: 1, outcome: .failed)
            )
            XCTAssertTrue(recover.generations.isEmpty)
            XCTAssertTrue(completions.values.isEmpty)
            XCTAssertEqual(scheduler.pendingCount, 0)
        }
    }

    func testGenerationIsExactAndRestartRejectionDoesNotPollOrComplete() throws {
        let scheduler = NetworkRecoveryManualScheduler()
        let recover = NetworkRecoveryCallRecorder(accepted: false)
        let observations = NetworkRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 0, hostState: "ready", registration: "ready")),
        ])
        let completions = NetworkRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            recover: recover.handler,
            observe: observations.handler
        )

        XCTAssertFalse(owner.start(
            pathGeneration: 0,
            completion: completions.handler
        ))
        XCTAssertFalse(owner.start(
            pathGeneration: 2,
            completion: completions.handler
        ))
        XCTAssertTrue(recover.generations.isEmpty)
        XCTAssertFalse(owner.start(
            pathGeneration: 1,
            completion: completions.handler
        ))
        XCTAssertEqual(recover.generations, [1])
        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(pathGeneration: 1, outcome: .failed)
        )
        XCTAssertFalse(owner.start(
            pathGeneration: 1,
            completion: completions.handler
        ))
        XCTAssertTrue(completions.values.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testForeignSleepEpochDriftAndIncompatibleReadyFailClosed() throws {
        let values: [HostCoreSnapshot] = [
            try snapshot(
                hostInstanceID: "foreign-host",
                epoch: 7,
                hostState: "ready",
                registration: "ready"
            ),
            try snapshot(epoch: 8, hostState: "ready", registration: "ready"),
            try snapshot(
                epoch: 7,
                status: .suspending,
                hostState: "starting",
                registration: "suspending"
            ),
            try snapshot(epoch: 7, hostState: "ready", registration: "pending"),
            try snapshot(epoch: 7, hostState: "starting", registration: "ready"),
        ]
        for value in values {
            XCTAssertEqual(
                HostAgentNetworkPathRecoveryPollingOwner.convergence(
                    observation: .snapshot(value),
                    expectedHostInstanceID: "host-a",
                    recoveryEpoch: 7
                ),
                .failed
            )
        }
        XCTAssertEqual(
            HostAgentNetworkPathRecoveryPollingOwner.convergence(
                observation: .unavailable,
                expectedHostInstanceID: "host-a",
                recoveryEpoch: 7
            ),
            .pending
        )
    }

    func testUnavailableObservationTimesOutAtExactAttemptBound() throws {
        let scheduler = NetworkRecoveryManualScheduler()
        let recover = NetworkRecoveryCallRecorder(accepted: true)
        let observations = NetworkRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 2, hostState: "ready", registration: "ready")),
            .unavailable,
            .unavailable,
            .unavailable,
        ])
        let completions = NetworkRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            maximumAttempts: 3,
            recover: recover.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(
            pathGeneration: 1,
            completion: completions.handler
        ))
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()

        XCTAssertEqual(observations.count, 4)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(pathGeneration: 1, outcome: .timedOut)
        )
        XCTAssertEqual(
            completions.values,
            [.init(pathGeneration: 1, succeeded: false)]
        )
    }

    func testDelayedTickPastDeadlineDoesNotCopyAnotherSnapshot() throws {
        let scheduler = NetworkRecoveryManualScheduler()
        let recover = NetworkRecoveryCallRecorder(accepted: true)
        let observations = NetworkRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 0, hostState: "ready", registration: "ready")),
            .failed,
        ])
        let completions = NetworkRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            recover: recover.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(
            pathGeneration: 1,
            completion: completions.handler
        ))
        scheduler.advance(by: 5_001)
        scheduler.runNext()

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(pathGeneration: 1, outcome: .timedOut)
        )
    }

    func testCancellationSuppressesScheduledAndFutureWork() throws {
        let scheduler = NetworkRecoveryManualScheduler()
        let recover = NetworkRecoveryCallRecorder(accepted: true)
        let observations = NetworkRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 1, hostState: "ready", registration: "ready")),
            .failed,
        ])
        let completions = NetworkRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            recover: recover.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(
            pathGeneration: 1,
            completion: completions.handler
        ))
        owner.cancelAndWait()
        scheduler.runNext()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(observations.count, 1)
        XCTAssertTrue(completions.values.isEmpty)
        XCTAssertFalse(owner.start(
            pathGeneration: 2,
            completion: completions.handler
        ))
        owner.cancelAndWait()
    }

    func testCancellationDrainsAcceptedBlockingRestartWithoutLatePolling() throws {
        let scheduler = NetworkRecoveryManualScheduler()
        let recover = NetworkRecoveryBlockingCall()
        let observations = NetworkRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 9, hostState: "ready", registration: "ready")),
            .failed,
        ])
        let completions = NetworkRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            recover: recover.handler,
            observe: observations.handler
        )
        let startResult = NetworkRecoveryBooleanBox()
        let startFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            startResult.value = owner.start(
                pathGeneration: 1,
                completion: completions.handler
            )
            startFinished.signal()
        }
        XCTAssertEqual(recover.entered.wait(timeout: .now() + 1), .success)

        let cancelFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            owner.cancelAndWait()
            cancelFinished.signal()
        }
        XCTAssertEqual(cancelFinished.wait(timeout: .now() + 0.05), .timedOut)
        recover.release.signal()
        XCTAssertEqual(startFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(cancelFinished.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(startResult.value)
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertTrue(completions.values.isEmpty)
    }

    private func makeOwner(
        scheduler: NetworkRecoveryManualScheduler,
        maximumAttempts: UInt64 = 100,
        recover: @escaping HostAgentNetworkPathRecoveryPollingOwner.Recover,
        observe: @escaping HostAgentNetworkPathRecoveryPollingOwner.Observe
    ) -> HostAgentNetworkPathRecoveryPollingOwner {
        HostAgentNetworkPathRecoveryPollingOwner(
            expectedHostInstanceID: "host-a",
            intervalMilliseconds: 50,
            maximumAttempts: maximumAttempts,
            timeoutMilliseconds: 50 * maximumAttempts,
            schedule: scheduler.handler,
            nowMilliseconds: scheduler.clock,
            recover: recover,
            observe: observe
        )
    }

    private func snapshot(
        hostInstanceID: String = "host-a",
        epoch: UInt64,
        status: HostRecoveryStatus = .running,
        hostState: String,
        registration: String
    ) throws -> HostCoreSnapshot {
        let document: [String: Any] = [
            "schemaVersion": 8,
            "hostInstanceId": hostInstanceID,
            "hostState": hostState,
            "localId": "123456789",
            "authenticatedConnectionCount": 1,
            "sessionAvailability": "available",
            "sessionUnavailableReason": NSNull(),
            "pendingApproval": NSNull(),
            "activeSession": NSNull(),
            "temporaryPasswordPresentation": ["policy": "redacted"],
            "passwordPolicy": [
                "localPasswordSet": false,
                "effectivePasswordSet": false,
                "usingPresetPassword": false,
                "changeAllowed": true,
                "strengthPolicy": [
                    "version": 1,
                    "minimumCharacters": 6,
                    "maximumCharacters": 128,
                    "maximumUtf8Bytes": 512,
                    "rejectsControlCharacters": true,
                    "rejectsOuterWhitespace": true,
                ],
            ],
            "registrationStatus": registration,
            "recoveryEpoch": epoch,
            "recoveryStatus": status.rawValue,
            "lastError": status == .failed
                ? "registration.runtimeExited"
                : NSNull(),
            "observedAt": 42,
        ]
        return try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(withJSONObject: document)
        )
    }
}

private final class NetworkRecoveryManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [NetworkRecoveryManualTask] = []
    private var currentMilliseconds: UInt64 = 0

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    var handler: HostAgentNetworkPathRecoveryPollingOwner.Scheduler {
        { [self] delayMilliseconds, action in
            let task = NetworkRecoveryManualTask(
                delayMilliseconds: delayMilliseconds,
                action: action
            )
            lock.lock()
            tasks.append(task)
            lock.unlock()
            return task
        }
    }

    var clock: HostAgentNetworkPathRecoveryPollingOwner.Clock {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return currentMilliseconds
        }
    }

    func runNext() {
        lock.lock()
        let task = tasks.isEmpty ? nil : tasks.removeFirst()
        if let task { currentMilliseconds += task.delayMilliseconds }
        lock.unlock()
        task?.run()
    }

    func advance(by milliseconds: UInt64) {
        lock.lock()
        currentMilliseconds += milliseconds
        lock.unlock()
    }
}

private final class NetworkRecoveryManualTask:
    HostAgentNetworkPathRecoveryScheduledTask,
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

private final class NetworkRecoveryCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let accepted: Bool
    private var storage: [UInt64] = []

    init(accepted: Bool) {
        self.accepted = accepted
    }

    var generations: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var handler: HostAgentNetworkPathRecoveryPollingOwner.Recover {
        { [self] generation in
            lock.lock()
            storage.append(generation)
            lock.unlock()
            return accepted
        }
    }
}

private final class NetworkRecoveryBlockingCall: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var handler: HostAgentNetworkPathRecoveryPollingOwner.Recover {
        { [self] _ in
            entered.signal()
            release.wait()
            return true
        }
    }
}

private final class NetworkRecoveryBooleanBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class NetworkRecoveryObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [HostAgentNetworkPathRecoveryObservation]
    private var observationCount = 0

    init(_ observations: [HostAgentNetworkPathRecoveryObservation]) {
        self.observations = observations
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observationCount
    }

    var handler: HostAgentNetworkPathRecoveryPollingOwner.Observe {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            observationCount += 1
            return observations.isEmpty ? .unavailable : observations.removeFirst()
        }
    }
}

private struct NetworkRecoveryCompletion: Equatable {
    let pathGeneration: UInt64
    let succeeded: Bool
}

private final class NetworkRecoveryCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NetworkRecoveryCompletion] = []

    var values: [NetworkRecoveryCompletion] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var handler: HostAgentNetworkPathRecoveryPollingOwner.Completion {
        { [self] pathGeneration, succeeded in
            lock.lock()
            storage.append(.init(
                pathGeneration: pathGeneration,
                succeeded: succeeded
            ))
            lock.unlock()
        }
    }
}
