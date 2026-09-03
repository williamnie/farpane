@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentSnapshotStateTests: XCTestCase {
    func testPublishesSanitizedProjectionWithoutRetainingRevealedPassword() throws {
        let state = HostAgentSnapshotState()
        let secret = "temporary-secret-must-not-be-retained"
        let snapshot = try coreSnapshot(
            host: "host-a",
            observedAt: 100,
            revealedPassword: secret
        )

        XCTAssertEqual(
            state.publish(
                snapshot,
                eventSequence: 7,
                expectedHostInstanceID: "host-a"
            ),
            .published(generation: 1)
        )

        let view = state.snapshot()
        XCTAssertEqual(view.status, .available)
        XCTAssertEqual(view.refreshGeneration, 1)
        XCTAssertEqual(view.eventSequence, 7)
        XCTAssertEqual(view.projection?.hostInstanceID, "host-a")
        XCTAssertEqual(view.projection?.hostState, "ready")
        XCTAssertEqual(view.projection?.sessionAvailability, .available)
        XCTAssertNil(view.projection?.sessionUnavailableReason)
        XCTAssertEqual(view.projection?.temporaryPasswordPolicy, "redacted")
        XCTAssertEqual(view.projection?.observedAt, 100)
        XCTAssertFalse(String(reflecting: view).contains(secret))
        XCTAssertEqual(view.failedRefreshCount, 0)
    }

    func testProjectionRetainsLimitedSessionUnavailableTuple() throws {
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(
                host: "host-a",
                observedAt: 100,
                sessionAvailability: .limited,
                sessionUnavailableReason: .sessionUnavailable
            ),
            eventSequence: 1,
            expectedHostInstanceID: "host-a"
        )

        let projection = try XCTUnwrap(state.snapshot().projection)
        XCTAssertEqual(projection.sessionAvailability, .limited)
        XCTAssertEqual(
            projection.sessionUnavailableReason,
            .sessionUnavailable
        )
    }

    func testHostInstanceMismatchFailsClosedAndClearsCurrentProjection() throws {
        let state = HostAgentSnapshotState()
        XCTAssertEqual(
            state.publish(
                try coreSnapshot(host: "host-a", observedAt: 100),
                eventSequence: 0,
                expectedHostInstanceID: nil
            ),
            .published(generation: 1)
        )

        XCTAssertEqual(
            state.publish(
                try coreSnapshot(host: "host-b", observedAt: 101),
                eventSequence: 1,
                expectedHostInstanceID: "host-a"
            ),
            .rejected(.hostInstanceMismatch)
        )

        let view = state.snapshot()
        XCTAssertEqual(view.status, .hostInstanceMismatch)
        XCTAssertEqual(view.hostInstanceID, "host-a")
        XCTAssertNil(view.projection)
        XCTAssertEqual(view.refreshGeneration, 2)
        XCTAssertEqual(view.failedRefreshCount, 1)
    }

    func testOlderObservedAtFailsClosedWithoutMovingAcceptedWatermark() throws {
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(host: "host-a", observedAt: 200),
            eventSequence: 1,
            expectedHostInstanceID: "host-a"
        )

        XCTAssertEqual(
            state.publish(
                try coreSnapshot(host: "host-a", observedAt: 199),
                eventSequence: 2,
                expectedHostInstanceID: "host-a"
            ),
            .rejected(.staleObservedAt)
        )

        let view = state.snapshot()
        XCTAssertEqual(view.status, .staleSnapshot)
        XCTAssertNil(view.projection)
        XCTAssertEqual(view.lastAcceptedObservedAt, 200)
        XCTAssertEqual(view.eventSequence, 2)
        XCTAssertEqual(view.failedRefreshCount, 1)
    }

    func testOlderEventSequenceCannotReplaceOrDegradeNewerProjection() throws {
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(host: "host-a", observedAt: 200),
            eventSequence: 5,
            expectedHostInstanceID: "host-a"
        )

        XCTAssertEqual(
            state.publish(
                try coreSnapshot(host: "host-a", observedAt: 201),
                eventSequence: 4,
                expectedHostInstanceID: "host-a"
            ),
            .rejected(.staleEventSequence)
        )

        let view = state.snapshot()
        XCTAssertEqual(view.status, .available)
        XCTAssertEqual(view.eventSequence, 5)
        XCTAssertEqual(view.projection?.observedAt, 200)
        XCTAssertEqual(view.failedRefreshCount, 1)

        state.recordCopyFailure(eventSequence: 4)
        let afterStaleFailure = state.snapshot()
        XCTAssertEqual(afterStaleFailure.status, .available)
        XCTAssertEqual(afterStaleFailure.eventSequence, 5)
        XCTAssertEqual(afterStaleFailure.projection?.observedAt, 200)
        XCTAssertEqual(afterStaleFailure.failedRefreshCount, 2)
    }

    func testCopyFailureIsSanitizedAndLaterPublishRecovers() throws {
        let state = HostAgentSnapshotState()

        state.recordCopyFailure(eventSequence: 3)
        var view = state.snapshot()
        XCTAssertEqual(view.status, .copyFailed)
        XCTAssertNil(view.projection)
        XCTAssertEqual(view.refreshGeneration, 1)
        XCTAssertEqual(view.failedRefreshCount, 1)

        XCTAssertEqual(
            state.publish(
                try coreSnapshot(host: "host-a", observedAt: 100),
                eventSequence: 4,
                expectedHostInstanceID: "host-a"
            ),
            .published(generation: 2)
        )
        view = state.snapshot()
        XCTAssertEqual(view.status, .available)
        XCTAssertEqual(view.eventSequence, 4)
        XCTAssertEqual(view.failedRefreshCount, 1)
    }

    func testCoordinatorCoalescesPreBindRequestsAndRefreshesAgain() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 101),
        ])

        coordinator.requestRefresh(eventSequence: 2, hostInstanceID: "host-a")
        coordinator.requestRefresh(eventSequence: 5, hostInstanceID: "host-a")
        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in }
        ))
        XCTAssertEqual(source.callCount, 1)
        XCTAssertEqual(state.snapshot().eventSequence, 5)

        coordinator.requestRefresh(eventSequence: 6, hostInstanceID: "host-a")
        XCTAssertEqual(source.callCount, 2)
        XCTAssertEqual(state.snapshot().eventSequence, 6)
        XCTAssertEqual(state.snapshot().projection?.observedAt, 101)
    }

    func testCoordinatorPollRefreshesWithoutAdvancingEventSequence() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 101),
        ])

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in }
        ))
        XCTAssertEqual(state.snapshot().eventSequence, 0)
        coordinator.requestPoll()

        let view = state.snapshot()
        XCTAssertEqual(source.callCount, 2)
        XCTAssertEqual(view.status, .available)
        XCTAssertEqual(view.refreshGeneration, 2)
        XCTAssertEqual(view.eventSequence, 0)
        XCTAssertEqual(view.projection?.observedAt, 101)
    }

    func testCoordinatorPublishesOnlyAcceptedSnapshotViews() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 99),
            try coreSnapshot(host: "host-a", observedAt: 101),
        ])
        let publishedGenerations = LockedSnapshotGenerations()

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in },
            onSnapshotPublished: { view in
                publishedGenerations.append(view.refreshGeneration)
            }
        ))
        coordinator.requestPoll()
        coordinator.requestPoll()

        XCTAssertEqual(publishedGenerations.snapshot(), [1, 3])
        XCTAssertEqual(state.snapshot().refreshGeneration, 3)
        XCTAssertEqual(state.snapshot().projection?.observedAt, 101)
    }

    func testCoordinatorPublishesOnlyExactRecoverySnapshots() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(
                host: "host-a",
                observedAt: 101,
                recoveryEpoch: 1,
                recoveryStatus: .suspending,
                registrationStatus: "suspending"
            ),
            try coreSnapshot(
                host: "host-a",
                observedAt: 102,
                recoveryEpoch: 1
            ),
        ])

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in }
        ))
        XCTAssertTrue(coordinator.publishRecoverySnapshot(
            expectedHostInstanceID: "host-a",
            epoch: 1,
            recoveryStatus: .suspending,
            registrationStatus: "suspending"
        ))
        var projection = try XCTUnwrap(state.snapshot().projection)
        XCTAssertEqual(projection.recoveryEpoch, 1)
        XCTAssertEqual(projection.recoveryStatus, .suspending)
        XCTAssertEqual(projection.registrationStatus, "suspending")

        XCTAssertTrue(coordinator.publishRecoverySnapshot(
            expectedHostInstanceID: "host-a",
            epoch: 1,
            recoveryStatus: .running,
            registrationStatus: "ready"
        ))
        projection = try XCTUnwrap(state.snapshot().projection)
        XCTAssertEqual(projection.recoveryEpoch, 1)
        XCTAssertEqual(projection.recoveryStatus, .running)
        XCTAssertEqual(projection.registrationStatus, "ready")
        XCTAssertEqual(source.callCount, 3)
    }

    func testCoordinatorRecoveryContradictionFailsClosed() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(
                host: "host-a",
                observedAt: 101,
                recoveryEpoch: 1,
                recoveryStatus: .resuming,
                registrationStatus: "pending"
            ),
        ])
        var invalidations: [HostAgentSnapshotIdentityInvalidationReason] = []

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { invalidations.append($0) }
        ))
        XCTAssertFalse(coordinator.publishRecoverySnapshot(
            expectedHostInstanceID: "host-a",
            epoch: 1,
            recoveryStatus: .suspending,
            registrationStatus: "suspending"
        ))

        let view = state.snapshot()
        XCTAssertEqual(view.status, .copyFailed)
        XCTAssertNil(view.projection)
        XCTAssertEqual(invalidations, [.copyFailed])
    }

    func testCoordinatorRecoveryPublicationWaitsForInflightRefresh() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = BlockingSnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(
                host: "host-a",
                observedAt: 101,
                recoveryEpoch: 1,
                recoveryStatus: .suspending,
                registrationStatus: "suspending"
            ),
        ])
        let bound = expectation(description: "initial refresh finished")
        let recoveryReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            XCTAssertTrue(coordinator.bind(
                copySnapshot: source.copy,
                onIdentityInvalidationRequired: { _ in }
            ))
            bound.fulfill()
        }
        XCTAssertEqual(source.firstCopyEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            XCTAssertTrue(coordinator.publishRecoverySnapshot(
                expectedHostInstanceID: "host-a",
                epoch: 1,
                recoveryStatus: .suspending,
                registrationStatus: "suspending"
            ))
            recoveryReturned.signal()
        }
        XCTAssertEqual(
            recoveryReturned.wait(timeout: .now() + 0.05),
            .timedOut
        )
        source.releaseFirstCopy.signal()
        wait(for: [bound], timeout: 2)
        XCTAssertEqual(recoveryReturned.wait(timeout: .now() + 2), .success)

        let projection = try XCTUnwrap(state.snapshot().projection)
        XCTAssertEqual(projection.recoveryEpoch, 1)
        XCTAssertEqual(projection.recoveryStatus, .suspending)
        XCTAssertEqual(source.callCount, 2)
    }

    func testCoordinatorCancelDrainsInflightRecoveryPublication() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = RecoveryBlockingSnapshotCopySource(
            initial: try coreSnapshot(host: "host-a", observedAt: 100),
            recovery: try coreSnapshot(
                host: "host-a",
                observedAt: 101,
                recoveryEpoch: 1,
                recoveryStatus: .suspending,
                registrationStatus: "suspending"
            )
        )
        let recoveryReturned = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in }
        ))
        DispatchQueue.global().async {
            XCTAssertFalse(coordinator.publishRecoverySnapshot(
                expectedHostInstanceID: "host-a",
                epoch: 1,
                recoveryStatus: .suspending,
                registrationStatus: "suspending"
            ))
            recoveryReturned.signal()
        }
        XCTAssertEqual(source.recoveryCopyEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            coordinator.cancelAndWait()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
        source.releaseRecoveryCopy.signal()
        XCTAssertEqual(recoveryReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(coordinator.publishRecoverySnapshot(
            expectedHostInstanceID: "host-a",
            epoch: 2,
            recoveryStatus: .suspending,
            registrationStatus: "suspending"
        ))
    }

    func testCoordinatorCoalescesPollArrivingDuringRefresh() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = BlockingSnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 101),
        ])
        let bound = expectation(description: "coordinator bound after poll")

        DispatchQueue.global().async {
            XCTAssertTrue(coordinator.bind(
                copySnapshot: source.copy,
                onIdentityInvalidationRequired: { _ in }
            ))
            bound.fulfill()
        }
        XCTAssertEqual(source.firstCopyEntered.wait(timeout: .now() + 2), .success)
        coordinator.requestPoll()
        coordinator.requestPoll()
        source.releaseFirstCopy.signal()
        wait(for: [bound], timeout: 2)

        XCTAssertEqual(source.callCount, 2)
        XCTAssertEqual(state.snapshot().refreshGeneration, 2)
        XCTAssertEqual(state.snapshot().eventSequence, 0)
        XCTAssertEqual(state.snapshot().projection?.observedAt, 101)
    }

    func testCoordinatorJournalsOneSemanticSessionTransitionAndRepublishesCursor()
        throws
    {
        let state = HostAgentSnapshotState()
        let eventState = try HostAgentEventState(
            capacity: 4,
            maximumEventBytes: 4_096
        )
        let coordinator = HostAgentSnapshotRefreshCoordinator(
            state: state,
            eventState: eventState
        )
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(
                host: "host-a",
                observedAt: 101,
                sessionAvailability: .limited,
                sessionUnavailableReason: .sessionUnavailable
            ),
            try coreSnapshot(
                host: "host-a",
                observedAt: 102,
                sessionAvailability: .limited,
                sessionUnavailableReason: .sessionUnavailable
            ),
            try coreSnapshot(
                host: "host-a",
                observedAt: 103,
                sessionAvailability: .limited,
                sessionUnavailableReason: .sessionUnavailable
            ),
        ])

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in }
        ))
        XCTAssertEqual(eventState.snapshot().latestSequence, 0)

        coordinator.requestPoll()

        let transitioned = state.snapshot()
        XCTAssertEqual(source.callCount, 3)
        XCTAssertEqual(transitioned.status, .available)
        XCTAssertEqual(transitioned.eventSequence, 1)
        XCTAssertEqual(transitioned.projection?.observedAt, 102)
        XCTAssertEqual(
            transitioned.projection?.sessionAvailability,
            .limited
        )
        XCTAssertEqual(eventState.snapshot().latestSequence, 1)
        guard case .snapshotChanged(let sentAt) =
            eventState.snapshot().records.first?.payload
        else { return XCTFail("expected local snapshot change marker") }
        XCTAssertEqual(sentAt, 101)

        coordinator.requestPoll()

        XCTAssertEqual(source.callCount, 4)
        XCTAssertEqual(state.snapshot().eventSequence, 1)
        XCTAssertEqual(eventState.snapshot().latestSequence, 1)
    }

    func testCoordinatorNotifiesRegistrationChangesWithoutRepeatingStablePolls()
        throws
    {
        for (initial, updated) in [("pending", "ready"), ("ready", "pending")] {
            let state = HostAgentSnapshotState()
            let eventState = try HostAgentEventState()
            let coordinator = HostAgentSnapshotRefreshCoordinator(
                state: state,
                eventState: eventState
            )
            let initialSnapshot = try coreSnapshot(
                host: "host-a",
                observedAt: 100,
                registrationStatus: initial
            )
            let updatedSnapshot = try coreSnapshot(
                host: "host-a",
                observedAt: 101,
                registrationStatus: updated
            )
            var current = initialSnapshot
            XCTAssertTrue(coordinator.bind(
                copySnapshot: { current },
                onIdentityInvalidationRequired: { _ in
                    XCTFail("注册状态变化不应使后台身份失效")
                }
            ))
            let initialCursor = state.snapshot().eventSequence
            XCTAssertEqual(eventState.snapshot().latestSequence, initialCursor)

            current = updatedSnapshot
            coordinator.requestPoll()

            XCTAssertEqual(state.snapshot().projection?.registrationStatus, updated)
            XCTAssertEqual(state.snapshot().eventSequence, initialCursor + 1)
            guard case .batch(let records, let latestSequence, false) =
                try eventState.replay(afterSequence: initialCursor)
            else { return XCTFail("前台必须收到重新读取快照的通知") }
            XCTAssertEqual(latestSequence, initialCursor + 1)
            XCTAssertEqual(records.count, 1)
            guard case .snapshotChanged(let sentAt) = records.first?.payload
            else { return XCTFail("expected snapshot change marker") }
            XCTAssertEqual(sentAt, 101)

            coordinator.requestPoll()
            XCTAssertEqual(state.snapshot().eventSequence, latestSequence)
            guard case .upToDate(let unchangedSequence) =
                try eventState.replay(afterSequence: latestSequence)
            else { return XCTFail("稳定状态不应反复通知前台") }
            XCTAssertEqual(unchangedSequence, latestSequence)
            coordinator.cancelAndWait()
        }
    }

    func testCoordinatorDrainsRequestArrivingDuringRefresh() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = BlockingSnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 101),
        ])
        let bound = expectation(description: "coordinator bound")

        DispatchQueue.global().async {
            XCTAssertTrue(coordinator.bind(
                copySnapshot: source.copy,
                onIdentityInvalidationRequired: { _ in }
            ))
            bound.fulfill()
        }
        XCTAssertEqual(source.firstCopyEntered.wait(timeout: .now() + 2), .success)
        coordinator.requestRefresh(eventSequence: 2, hostInstanceID: "host-a")
        source.releaseFirstCopy.signal()
        wait(for: [bound], timeout: 2)

        let view = state.snapshot()
        XCTAssertEqual(source.callCount, 2)
        XCTAssertEqual(view.status, .available)
        XCTAssertEqual(view.refreshGeneration, 2)
        XCTAssertEqual(view.eventSequence, 2)
        XCTAssertEqual(view.projection?.observedAt, 101)
    }

    func testCoordinatorSanitizesCopyFailureAndRejectsSecondBinding() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        var attempts = 0

        XCTAssertTrue(coordinator.bind(
            copySnapshot: {
                attempts += 1
                if attempts == 1 { throw SnapshotCopyTestError.secretBearing }
                return try self.coreSnapshot(host: "host-a", observedAt: 100)
            },
            onIdentityInvalidationRequired: { _ in }
        ))
        XCTAssertEqual(state.snapshot().status, .copyFailed)
        XCTAssertFalse(coordinator.bind(
            copySnapshot: {
                try self.coreSnapshot(host: "replacement", observedAt: 999)
            },
            onIdentityInvalidationRequired: { _ in }
        ))

        coordinator.requestRefresh(eventSequence: 1, hostInstanceID: "host-a")
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(state.snapshot().status, .available)
        XCTAssertEqual(state.snapshot().projection?.hostInstanceID, "host-a")
    }

    func testCoordinatorRequiresOneIdentityInvalidationAfterCopyFailure() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        var attempts = 0
        var invalidationReasons: [HostAgentSnapshotIdentityInvalidationReason] = []

        XCTAssertTrue(coordinator.bind(
            copySnapshot: {
                attempts += 1
                if attempts == 2 { throw SnapshotCopyTestError.secretBearing }
                return try self.coreSnapshot(
                    host: "host-a",
                    observedAt: UInt64(100 + attempts)
                )
            },
            onIdentityInvalidationRequired: { reason in
                invalidationReasons.append(reason)
            }
        ))
        coordinator.requestPoll()
        coordinator.requestPoll()

        XCTAssertEqual(state.snapshot().status, .available)
        XCTAssertEqual(invalidationReasons, [.copyFailed])
    }

    func testCoordinatorInvalidatesForHostContradictionButNotStaleSnapshot() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = SnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 99),
            try coreSnapshot(host: "host-b", observedAt: 101),
        ])
        var invalidationReasons: [HostAgentSnapshotIdentityInvalidationReason] = []

        XCTAssertTrue(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { reason in
                invalidationReasons.append(reason)
            }
        ))
        coordinator.requestPoll()
        XCTAssertEqual(state.snapshot().status, .staleSnapshot)
        XCTAssertTrue(invalidationReasons.isEmpty)

        coordinator.requestRefresh(eventSequence: 1, hostInstanceID: "host-a")
        XCTAssertEqual(state.snapshot().status, .hostInstanceMismatch)
        XCTAssertEqual(invalidationReasons, [.hostInstanceMismatch])
    }

    func testCoordinatorCancelWaitsForRefreshAndRejectsFutureRequests() throws {
        let state = HostAgentSnapshotState()
        let coordinator = HostAgentSnapshotRefreshCoordinator(state: state)
        let source = BlockingSnapshotCopySource(snapshots: [
            try coreSnapshot(host: "host-a", observedAt: 100),
            try coreSnapshot(host: "host-a", observedAt: 101),
        ])
        let bound = expectation(description: "coordinator bind returned")
        let cancelReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            XCTAssertTrue(coordinator.bind(
                copySnapshot: source.copy,
                onIdentityInvalidationRequired: { _ in }
            ))
            bound.fulfill()
        }
        XCTAssertEqual(source.firstCopyEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            coordinator.cancelAndWait()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
        coordinator.requestPoll()
        coordinator.requestRefresh(eventSequence: 1, hostInstanceID: "host-a")
        source.releaseFirstCopy.signal()
        wait(for: [bound], timeout: 2)
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)

        coordinator.requestPoll()
        coordinator.requestRefresh(eventSequence: 2, hostInstanceID: "host-a")
        XCTAssertFalse(coordinator.bind(
            copySnapshot: source.copy,
            onIdentityInvalidationRequired: { _ in }
        ))
        XCTAssertEqual(source.callCount, 1)
        XCTAssertEqual(state.snapshot().refreshGeneration, 1)
    }

    private func coreSnapshot(
        host: String,
        observedAt: UInt64,
        revealedPassword: String? = nil,
        sessionAvailability: HostSessionAvailability = .available,
        sessionUnavailableReason: HostSessionUnavailableReason? = nil,
        recoveryEpoch: UInt64 = 0,
        recoveryStatus: HostRecoveryStatus = .running,
        registrationStatus: String? = nil
    ) throws -> HostCoreSnapshot {
        let presentation: [String: Any] = revealedPassword.map {
            ["policy": "revealed", "value": $0]
        } ?? ["policy": "redacted"]
        let document: [String: Any] = [
            "schemaVersion": 8,
            "hostInstanceId": host,
            "hostState": recoveryStatus == .running && registrationStatus != "pending"
                ? "ready" : "starting",
            "localId": "123456789",
            "authenticatedConnectionCount": 1,
            "sessionAvailability": sessionAvailability.rawValue,
            "sessionUnavailableReason": sessionUnavailableReason.map {
                $0.rawValue as Any
            } ?? NSNull(),
            "registrationStatus": registrationStatus
                ?? (recoveryStatus == .running ? "ready" : "pending"),
            "recoveryEpoch": recoveryEpoch,
            "recoveryStatus": recoveryStatus.rawValue,
            "pendingApproval": NSNull(),
            "activeSession": NSNull(),
            "temporaryPasswordPresentation": presentation,
            "passwordPolicy": [
                "localPasswordSet": true,
                "effectivePasswordSet": true,
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
            "lastError": NSNull(),
            "observedAt": observedAt,
        ]
        return try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(withJSONObject: document)
        )
    }
}

private enum SnapshotCopyTestError: Error {
    case secretBearing
}

private final class LockedSnapshotGenerations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64] = []

    func append(_ value: UInt64) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class SnapshotCopySource: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [HostCoreSnapshot]
    private(set) var callCount = 0

    init(snapshots: [HostCoreSnapshot]) {
        self.snapshots = snapshots
    }

    func copy() throws -> HostCoreSnapshot {
        lock.lock(); defer { lock.unlock() }
        callCount += 1
        return snapshots.removeFirst()
    }
}

private final class BlockingSnapshotCopySource: @unchecked Sendable {
    let firstCopyEntered = DispatchSemaphore(value: 0)
    let releaseFirstCopy = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var snapshots: [HostCoreSnapshot]
    private(set) var callCount = 0

    init(snapshots: [HostCoreSnapshot]) {
        self.snapshots = snapshots
    }

    func copy() throws -> HostCoreSnapshot {
        lock.lock()
        callCount += 1
        let currentCall = callCount
        let snapshot = snapshots.removeFirst()
        lock.unlock()
        if currentCall == 1 {
            firstCopyEntered.signal()
            releaseFirstCopy.wait()
        }
        return snapshot
    }
}

private final class RecoveryBlockingSnapshotCopySource: @unchecked Sendable {
    let recoveryCopyEntered = DispatchSemaphore(value: 0)
    let releaseRecoveryCopy = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let initial: HostCoreSnapshot
    private let recovery: HostCoreSnapshot
    private var callCount = 0

    init(initial: HostCoreSnapshot, recovery: HostCoreSnapshot) {
        self.initial = initial
        self.recovery = recovery
    }

    func copy() throws -> HostCoreSnapshot {
        lock.lock()
        callCount += 1
        let currentCall = callCount
        lock.unlock()
        if currentCall == 1 { return initial }
        recoveryCopyEntered.signal()
        releaseRecoveryCopy.wait()
        return recovery
    }
}
