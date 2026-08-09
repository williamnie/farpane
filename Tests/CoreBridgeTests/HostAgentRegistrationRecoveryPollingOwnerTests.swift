@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentRegistrationRecoveryPollingOwnerTests: XCTestCase {
    func testProductWindowIsExactlyBoundedAtFiveSeconds() {
        XCTAssertEqual(
            HostAgentRegistrationRecoveryPollingOwner.productIntervalMilliseconds,
            50
        )
        XCTAssertEqual(
            HostAgentRegistrationRecoveryPollingOwner.productMaximumAttempts,
            100
        )
        XCTAssertEqual(
            HostAgentRegistrationRecoveryPollingOwner.productTimeoutMilliseconds,
            5_000
        )
    }

    func testStaleAndResumingSnapshotsWaitForExactRunningReady() throws {
        let scheduler = RegistrationRecoveryManualScheduler()
        let resume = RegistrationRecoveryResumeRecorder(accepted: true)
        let observations = RegistrationRecoveryObservationRecorder([
            .snapshot(try snapshot(epoch: 3, status: .running)),
            .snapshot(try snapshot(epoch: 4, status: .resuming)),
            .snapshot(try snapshot(epoch: 4, status: .running)),
        ])
        let completions = RegistrationRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            resume: resume.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(epoch: 4, completion: completions.handler))
        XCTAssertEqual(resume.epochs, [4])
        XCTAssertEqual(owner.stateSnapshot(), .polling(epoch: 4, attempt: 0))
        scheduler.runNext()
        XCTAssertEqual(owner.stateSnapshot(), .polling(epoch: 4, attempt: 1))
        scheduler.runNext()
        XCTAssertEqual(owner.stateSnapshot(), .polling(epoch: 4, attempt: 2))
        scheduler.runNext()

        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(epoch: 4, outcome: .converged)
        )
        XCTAssertEqual(completions.values, [.init(epoch: 4, succeeded: true)])
        XCTAssertFalse(owner.start(epoch: 4, completion: completions.handler))
    }

    func testForeignFutureFailedAndIncompatibleSnapshotsFailClosed() throws {
        let expectedHost = "host-a"
        let future = try snapshot(epoch: 6, status: .running)
        let foreign = try snapshot(
            hostInstanceID: "host-b",
            epoch: 5,
            status: .running
        )
        let failed = try snapshot(epoch: 5, status: .failed)
        let incompatible = try snapshot(
            epoch: 5,
            status: .running,
            registrationStatus: "pending"
        )

        for value in [future, foreign, failed, incompatible] {
            XCTAssertEqual(
                HostAgentRegistrationRecoveryPollingOwner.convergence(
                    observation: .snapshot(value),
                    expectedHostInstanceID: expectedHost,
                    epoch: 5
                ),
                .failed
            )
        }
    }

    func testUnavailableObservationTimesOutAtExactAttemptBound() {
        let scheduler = RegistrationRecoveryManualScheduler()
        let resume = RegistrationRecoveryResumeRecorder(accepted: true)
        let observations = RegistrationRecoveryObservationRecorder([
            .unavailable, .unavailable, .unavailable,
        ])
        let completions = RegistrationRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            maximumAttempts: 3,
            resume: resume.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
        scheduler.runNext()
        scheduler.runNext()
        scheduler.runNext()

        XCTAssertEqual(observations.count, 3)
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(epoch: 1, outcome: .timedOut)
        )
        XCTAssertEqual(completions.values, [.init(epoch: 1, succeeded: false)])
    }

    func testResumeRejectionDoesNotScheduleOrComplete() {
        let scheduler = RegistrationRecoveryManualScheduler()
        let resume = RegistrationRecoveryResumeRecorder(accepted: false)
        let observations = RegistrationRecoveryObservationRecorder([.failed])
        let completions = RegistrationRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            resume: resume.handler,
            observe: observations.handler
        )

        XCTAssertFalse(owner.start(epoch: 1, completion: completions.handler))
        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(epoch: 1, outcome: .failed)
        )
        XCTAssertEqual(resume.epochs, [1])
        XCTAssertEqual(scheduler.pendingCount, 0)
        XCTAssertEqual(observations.count, 0)
        XCTAssertTrue(completions.values.isEmpty)
    }

    func testDelayedTickPastDeadlineTimesOutWithoutSnapshotCopy() {
        let scheduler = RegistrationRecoveryManualScheduler()
        let resume = RegistrationRecoveryResumeRecorder(accepted: true)
        let observations = RegistrationRecoveryObservationRecorder([.failed])
        let completions = RegistrationRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            maximumAttempts: 100,
            resume: resume.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
        scheduler.advance(by: 5_001)
        scheduler.runNext()

        XCTAssertEqual(observations.count, 0)
        XCTAssertEqual(
            owner.stateSnapshot(),
            .completed(epoch: 1, outcome: .timedOut)
        )
    }

    func testCancellationSuppressesScheduledAndFutureWork() {
        let scheduler = RegistrationRecoveryManualScheduler()
        let resume = RegistrationRecoveryResumeRecorder(accepted: true)
        let observations = RegistrationRecoveryObservationRecorder([.failed])
        let completions = RegistrationRecoveryCompletionRecorder()
        let owner = makeOwner(
            scheduler: scheduler,
            resume: resume.handler,
            observe: observations.handler
        )

        XCTAssertTrue(owner.start(epoch: 1, completion: completions.handler))
        owner.cancelAndWait()
        scheduler.runNext()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(observations.count, 0)
        XCTAssertTrue(completions.values.isEmpty)
        XCTAssertFalse(owner.start(epoch: 2, completion: completions.handler))
        owner.cancelAndWait()
    }

    private func makeOwner(
        scheduler: RegistrationRecoveryManualScheduler,
        maximumAttempts: UInt64 = 100,
        resume: @escaping HostAgentRegistrationRecoveryPollingOwner.Resume,
        observe: @escaping HostAgentRegistrationRecoveryPollingOwner.Observe
    ) -> HostAgentRegistrationRecoveryPollingOwner {
        HostAgentRegistrationRecoveryPollingOwner(
            expectedHostInstanceID: "host-a",
            intervalMilliseconds: 50,
            maximumAttempts: maximumAttempts,
            timeoutMilliseconds: 50 * maximumAttempts,
            schedule: scheduler.handler,
            nowMilliseconds: scheduler.clock,
            resume: resume,
            observe: observe
        )
    }

    private func snapshot(
        hostInstanceID: String = "host-a",
        epoch: UInt64,
        status: HostRecoveryStatus,
        registrationStatus: String? = nil
    ) throws -> HostCoreSnapshot {
        let defaults: (hostState: String, registrationStatus: String, error: Any)
        switch status {
        case .running:
            defaults = ("ready", "ready", NSNull())
        case .resuming:
            defaults = ("starting", "pending", NSNull())
        case .suspending:
            defaults = ("starting", "suspending", NSNull())
        case .suspended:
            defaults = ("starting", "suspended", NSNull())
        case .failed:
            defaults = ("error", "degraded", "registration.runtimeExited")
        }
        let document: [String: Any] = [
            "schemaVersion": 6,
            "hostInstanceId": hostInstanceID,
            "hostState": defaults.hostState,
            "localId": "123456789",
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
            "registrationStatus": registrationStatus ?? defaults.registrationStatus,
            "recoveryEpoch": epoch,
            "recoveryStatus": status.rawValue,
            "lastError": defaults.error,
            "observedAt": 42,
        ]
        return try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(withJSONObject: document)
        )
    }
}

private final class RegistrationRecoveryManualScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [RegistrationRecoveryManualTask] = []
    private var currentMilliseconds: UInt64 = 0

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tasks.count
    }

    var handler: HostAgentRegistrationRecoveryPollingOwner.Scheduler {
        { [self] delayMilliseconds, action in
            let task = RegistrationRecoveryManualTask(
                delayMilliseconds: delayMilliseconds,
                action: action
            )
            lock.lock()
            tasks.append(task)
            lock.unlock()
            return task
        }
    }

    var clock: HostAgentRegistrationRecoveryPollingOwner.Clock {
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

private final class RegistrationRecoveryManualTask:
    HostAgentRegistrationRecoveryScheduledTask,
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

private final class RegistrationRecoveryResumeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let accepted: Bool
    private var storage: [UInt64] = []

    init(accepted: Bool) {
        self.accepted = accepted
    }

    var epochs: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var handler: HostAgentRegistrationRecoveryPollingOwner.Resume {
        { [self] epoch in
            lock.lock()
            storage.append(epoch)
            lock.unlock()
            return accepted
        }
    }
}

private final class RegistrationRecoveryObservationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [HostAgentRegistrationRecoveryObservation]
    private var observationCount = 0

    init(_ observations: [HostAgentRegistrationRecoveryObservation]) {
        self.observations = observations
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return observationCount
    }

    var handler: HostAgentRegistrationRecoveryPollingOwner.Observe {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            observationCount += 1
            return observations.isEmpty ? .unavailable : observations.removeFirst()
        }
    }
}

private struct RegistrationRecoveryCompletion: Equatable {
    let epoch: UInt64
    let succeeded: Bool
}

private final class RegistrationRecoveryCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RegistrationRecoveryCompletion] = []

    var values: [RegistrationRecoveryCompletion] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var handler: HostAgentRegistrationRecoveryPollingOwner.Completion {
        { [self] epoch, succeeded in
            lock.lock()
            storage.append(.init(epoch: epoch, succeeded: succeeded))
            lock.unlock()
        }
    }
}
