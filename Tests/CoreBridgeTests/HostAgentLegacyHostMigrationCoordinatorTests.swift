@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentLegacyHostMigrationCoordinatorTests: XCTestCase {
    func testConstructionIsInert() {
        let dependencies = MigrationCoordinatorDependencies([
            .quiescent,
        ])
        let coordinator = makeCoordinator(dependencies)

        XCTAssertEqual(coordinator.snapshot().phase, .idle)
        XCTAssertEqual(dependencies.events, [])
    }

    func testAlreadyQuiescentEvidenceBecomesReadyWithoutMutation() {
        let dependencies = MigrationCoordinatorDependencies([
            .quiescent,
        ])
        let coordinator = makeCoordinator(dependencies)

        XCTAssertTrue(coordinator.apply(.prepareForBackgroundRegistration))

        XCTAssertEqual(coordinator.snapshot().phase, .readyForRegistration)
        XCTAssertEqual(dependencies.events, [.captureEvidence])
    }

    func testUnavailableOrInconsistentInitialEvidenceFailsWithoutMutation() {
        let cases: [
            (
                HostAgentLegacyHostMigrationEvidence,
                HostAgentLegacyHostMigrationFailure
            )
        ] = [
            (
                .quiescent.with(.preferenceEnabled, .unavailable),
                .evidenceUnavailable
            ),
            (
                .quiescent.with(.activeSession, .present),
                .inconsistentEvidence
            ),
        ]

        for (evidence, failure) in cases {
            let dependencies = MigrationCoordinatorDependencies([evidence])
            let coordinator = makeCoordinator(dependencies)

            XCTAssertFalse(
                coordinator.apply(.prepareForBackgroundRegistration)
            )
            XCTAssertEqual(
                coordinator.snapshot().phase,
                .failed(.assessment(failure))
            )
            XCTAssertEqual(dependencies.events, [.captureEvidence])
        }
    }

    func testPendingApprovalOrActiveSessionBlocksWithoutStoppingLegacyHost() {
        for field in [
            LegacyMigrationEvidenceField.pendingApproval,
            .activeSession,
        ] {
            let evidence = HostAgentLegacyHostMigrationEvidence.running
                .with(field, .present)
            let dependencies = MigrationCoordinatorDependencies([evidence])
            let coordinator = makeCoordinator(dependencies)

            XCTAssertFalse(
                coordinator.apply(.prepareForBackgroundRegistration)
            )

            guard case .blocked(let blockers) = coordinator.snapshot().phase
            else { return XCTFail("expected session blocker") }
            XCTAssertTrue(blockers.contains(
                field == .pendingApproval ? .pendingApproval : .activeSession
            ))
            XCTAssertEqual(dependencies.events, [.captureEvidence])
        }
    }

    func testSafeLegacyOwnershipRequestsQuiescenceThenUsesFreshEvidence() {
        let dependencies = MigrationCoordinatorDependencies([
            .running,
            .quiescent,
        ])
        let coordinator = makeCoordinator(dependencies)

        XCTAssertTrue(coordinator.apply(.prepareForBackgroundRegistration))

        XCTAssertEqual(coordinator.snapshot().phase, .readyForRegistration)
        XCTAssertEqual(
            dependencies.events,
            [.captureEvidence, .requestQuiescence, .captureEvidence]
        )
        XCTAssertEqual(dependencies.quiescenceRequestCount, 1)
    }

    func testFailedQuiescenceRequestRecapturesButCannotBecomeReady() {
        let dependencies = MigrationCoordinatorDependencies([
            .running,
            .quiescent,
        ])
        dependencies.requestResult = .failed
        let coordinator = makeCoordinator(dependencies)

        XCTAssertFalse(coordinator.apply(.prepareForBackgroundRegistration))

        XCTAssertEqual(
            coordinator.snapshot().phase,
            .failed(.quiescenceRequestFailed)
        )
        XCTAssertEqual(
            dependencies.events,
            [.captureEvidence, .requestQuiescence, .captureEvidence]
        )
    }

    func testCompletedRequestCannotHideRemainingFreshBlockers() {
        let retainedClient = HostAgentLegacyHostMigrationEvidence.quiescent
            .with(.clientRetained, .present)
        let dependencies = MigrationCoordinatorDependencies([
            .running,
            retainedClient,
        ])
        let coordinator = makeCoordinator(dependencies)

        XCTAssertFalse(coordinator.apply(.prepareForBackgroundRegistration))

        XCTAssertEqual(
            coordinator.snapshot().phase,
            .blocked([.clientRetained])
        )
        XCTAssertEqual(dependencies.quiescenceRequestCount, 1)
    }

    func testInvalidFreshEvidenceFailsClosedAfterCompletedRequest() {
        let invalidFreshEvidence = HostAgentLegacyHostMigrationEvidence
            .quiescent.with(.pollerActive, .unavailable)
        let dependencies = MigrationCoordinatorDependencies([
            .running,
            invalidFreshEvidence,
        ])
        let coordinator = makeCoordinator(dependencies)

        XCTAssertFalse(coordinator.apply(.prepareForBackgroundRegistration))

        XCTAssertEqual(
            coordinator.snapshot().phase,
            .failed(.assessment(.evidenceUnavailable))
        )
        XCTAssertEqual(dependencies.quiescenceRequestCount, 1)
    }

    func testConcurrentOrReentrantRequestCannotDuplicateQuiescence() {
        let requestEntered = DispatchSemaphore(value: 0)
        let releaseRequest = DispatchSemaphore(value: 0)
        let dependencies = MigrationCoordinatorDependencies([
            .running,
            .quiescent,
        ])
        let coordinatorHolder = MigrationLockedValue<
            HostAgentLegacyHostMigrationCoordinator?
        >(nil)
        let reentrantResult = MigrationLockedValue<Bool?>(nil)
        dependencies.requestAction = {
            reentrantResult.set(
                coordinatorHolder.value?.apply(
                    .prepareForBackgroundRegistration
                )
            )
            requestEntered.signal()
            _ = releaseRequest.wait(timeout: .now() + 2)
        }
        let coordinator = makeCoordinator(dependencies)
        coordinatorHolder.set(coordinator)
        let firstResult = MigrationLockedValue<Bool?>(nil)
        let finished = expectation(description: "migration finished")
        DispatchQueue.global().async {
            firstResult.set(
                coordinator.apply(.prepareForBackgroundRegistration)
            )
            finished.fulfill()
        }
        XCTAssertEqual(requestEntered.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(coordinator.apply(.prepareForBackgroundRegistration))
        releaseRequest.signal()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(firstResult.value, true)
        XCTAssertEqual(reentrantResult.value, false)
        XCTAssertEqual(dependencies.quiescenceRequestCount, 1)
        XCTAssertEqual(coordinator.snapshot().phase, .readyForRegistration)
    }

    func testCoordinatorHasNoProductOrRegistrationAuthority() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentLegacyHostMigrationCoordinator.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "import AppKit",
            "import ServiceManagement",
            "UserDefaults",
            "HostControlClient",
            "SMAppService",
            "stopHostMode",
            ".register()",
            ".unregister()",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

private func makeCoordinator(
    _ dependencies: MigrationCoordinatorDependencies
) -> HostAgentLegacyHostMigrationCoordinator {
    HostAgentLegacyHostMigrationCoordinator(
        captureEvidence: { dependencies.captureEvidence() },
        requestQuiescence: { dependencies.requestQuiescence() }
    )
}

private enum MigrationCoordinatorEvent: Equatable {
    case captureEvidence
    case requestQuiescence
}

private final class MigrationCoordinatorDependencies: @unchecked Sendable {
    private let lock = NSLock()
    private var evidence: [HostAgentLegacyHostMigrationEvidence]
    private var recordedEvents: [MigrationCoordinatorEvent] = []
    private var recordedQuiescenceRequestCount = 0
    var requestResult = HostAgentLegacyHostQuiescenceRequestResult.completed
    var requestAction: @Sendable () -> Void = {}

    init(_ evidence: [HostAgentLegacyHostMigrationEvidence]) {
        self.evidence = evidence
    }

    var events: [MigrationCoordinatorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var quiescenceRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedQuiescenceRequestCount
    }

    func captureEvidence() -> HostAgentLegacyHostMigrationEvidence {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(.captureEvidence)
        guard !evidence.isEmpty else {
            return .quiescent.with(.runtimeActive, .unavailable)
        }
        return evidence.removeFirst()
    }

    func requestQuiescence() -> HostAgentLegacyHostQuiescenceRequestResult {
        lock.lock()
        recordedEvents.append(.requestQuiescence)
        recordedQuiescenceRequestCount += 1
        let result = requestResult
        let action = requestAction
        lock.unlock()
        action()
        return result
    }
}

private final class MigrationLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private enum LegacyMigrationEvidenceField {
    case preferenceEnabled
    case runtimeActive
    case clientRetained
    case pendingApproval
    case activeSession
    case mediaPipelineActive
    case pollerActive
}

private extension HostAgentLegacyHostMigrationEvidence {
    static let quiescent = HostAgentLegacyHostMigrationEvidence(
        preferenceEnabled: .absent,
        runtimeActive: .absent,
        clientRetained: .absent,
        pendingApproval: .absent,
        activeSession: .absent,
        mediaPipelineActive: .absent,
        pollerActive: .absent
    )

    static let running = HostAgentLegacyHostMigrationEvidence(
        preferenceEnabled: .present,
        runtimeActive: .present,
        clientRetained: .present,
        pendingApproval: .absent,
        activeSession: .absent,
        mediaPipelineActive: .present,
        pollerActive: .present
    )

    func with(
        _ field: LegacyMigrationEvidenceField,
        _ value: HostAgentLegacyHostMigrationEvidenceStatus
    ) -> Self {
        HostAgentLegacyHostMigrationEvidence(
            preferenceEnabled: field == .preferenceEnabled
                ? value : preferenceEnabled,
            runtimeActive: field == .runtimeActive ? value : runtimeActive,
            clientRetained: field == .clientRetained ? value : clientRetained,
            pendingApproval: field == .pendingApproval
                ? value : pendingApproval,
            activeSession: field == .activeSession ? value : activeSession,
            mediaPipelineActive: field == .mediaPipelineActive
                ? value : mediaPipelineActive,
            pollerActive: field == .pollerActive ? value : pollerActive
        )
    }
}
