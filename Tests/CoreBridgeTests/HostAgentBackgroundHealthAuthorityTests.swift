@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundHealthAuthorityTests: XCTestCase {
    func testInitialSnapshotIsConservativeAndConstructionDoesNotPublish() {
        let observations = BackgroundHealthRecorder()
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: { observations.append($0) }
        )

        let view = authority.snapshot()
        XCTAssertEqual(view.generation, 0)
        XCTAssertEqual(view.registration, .enabled)
        XCTAssertEqual(view.runtime.projectionGeneration, 0)
        XCTAssertEqual(view.runtime.handshake, .disconnected)
        XCTAssertEqual(view.runtime.snapshot, .unavailable)
        XCTAssertEqual(view.runtime.session, .unavailable)
        XCTAssertEqual(view.runtime.rendezvous, .checking)
        XCTAssertEqual(view.availability, .waitingForHandshake)
        XCTAssertFalse(view.isReady)
        XCTAssertTrue(observations.values.isEmpty)
    }

    func testReadyRequiresRegistrationAndOneCoherentRuntimeObservation() {
        let observations = BackgroundHealthRecorder()
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: { observations.append($0) }
        )

        authority.acceptRuntimeEvidence(healthyEvidence(generation: 2))

        let view = authority.snapshot()
        XCTAssertEqual(view.generation, 1)
        XCTAssertEqual(view.runtime.projectionGeneration, 2)
        XCTAssertEqual(view.availability, .ready)
        XCTAssertTrue(view.isReady)
        XCTAssertEqual(observations.values, [view])
    }

    func testRegistrationRefreshRevokesAndRestoresReadyWithoutStartingRuntime() {
        let registration = RegistrationSequence([
            .notRegistered,
            .enabled,
        ])
        let observations = BackgroundHealthRecorder()
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { registration.next() },
            observer: { observations.append($0) }
        )
        authority.acceptRuntimeEvidence(healthyEvidence(generation: 1))
        XCTAssertTrue(authority.snapshot().isReady)

        authority.refreshRegistration()
        XCTAssertEqual(authority.snapshot().registration, .notRegistered)
        XCTAssertEqual(authority.snapshot().availability, .notRegistered)
        XCTAssertFalse(authority.snapshot().isReady)

        authority.refreshRegistration()
        XCTAssertEqual(authority.snapshot().registration, .enabled)
        XCTAssertEqual(authority.snapshot().availability, .ready)
        XCTAssertEqual(registration.readCount, 2)
        XCTAssertEqual(observations.values.count, 3)
    }

    func testRuntimeRegressionImmediatelyWithdrawsReady() {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        authority.acceptRuntimeEvidence(healthyEvidence(generation: 1))

        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: 2,
            handshake: .disconnected,
            snapshot: .unavailable,
            session: .unavailable,
            rendezvous: .offline
        ))

        XCTAssertEqual(authority.snapshot().availability, .waitingForHandshake)
        XCTAssertFalse(authority.snapshot().isReady)
    }

    func testProjectionAndRegistrationPublicationsRemainSerialized() {
        let firstObserverEntered = expectation(
            description: "first observer entered"
        )
        let releaseFirstObserver = DispatchSemaphore(value: 0)
        let registration = RegistrationSequence([.notRegistered])
        let observations = BackgroundHealthRecorder()
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { registration.next() },
            observer: { view in
                observations.append(view)
                if view.generation == 1 {
                    firstObserverEntered.fulfill()
                    _ = releaseFirstObserver.wait(timeout: .now() + 2)
                }
            }
        )
        let projectionFinished = expectation(
            description: "projection finished"
        )
        let registrationFinished = expectation(
            description: "registration finished"
        )
        let healthyEvidence = healthyEvidence(generation: 1)

        DispatchQueue.global().async {
            authority.acceptRuntimeEvidence(healthyEvidence)
            projectionFinished.fulfill()
        }
        wait(for: [firstObserverEntered], timeout: 1)
        DispatchQueue.global().async {
            authority.refreshRegistration()
            registrationFinished.fulfill()
        }

        XCTAssertEqual(registration.currentReadCount(), 0)
        releaseFirstObserver.signal()
        wait(
            for: [projectionFinished, registrationFinished],
            timeout: 2
        )

        XCTAssertEqual(
            observations.values.map(\.availability),
            [.ready, .notRegistered]
        )
        XCTAssertEqual(authority.snapshot().generation, 2)
        XCTAssertEqual(authority.snapshot().availability, .notRegistered)
    }

    func testDuplicateAndStaleRuntimeEvidenceAreIgnored() {
        let observations = BackgroundHealthRecorder()
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled },
            observer: { observations.append($0) }
        )
        let current = healthyEvidence(generation: 3)
        authority.acceptRuntimeEvidence(current)

        authority.acceptRuntimeEvidence(current)
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: 2,
            handshake: .disconnected,
            snapshot: .unavailable,
            session: .unavailable,
            rendezvous: .offline
        ))

        XCTAssertEqual(authority.snapshot().runtime, current)
        XCTAssertEqual(authority.snapshot().generation, 1)
        XCTAssertEqual(observations.values.count, 1)
    }

    func testContradictoryOrMutatedSameGenerationFailsClosedPermanently() {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        authority.acceptRuntimeEvidence(healthyEvidence(generation: 3))

        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: 3,
            handshake: .compatible,
            snapshot: .unavailable,
            session: .unavailable,
            rendezvous: .checking
        ))
        XCTAssertEqual(authority.snapshot().failure, .invalidRuntimeEvidence)
        XCTAssertEqual(
            authority.snapshot().availability,
            .runtimeEvidenceInvalid
        )
        XCTAssertFalse(authority.snapshot().isReady)

        authority.acceptRuntimeEvidence(healthyEvidence(generation: 4))
        authority.refreshRegistration()
        XCTAssertEqual(authority.snapshot().failure, .invalidRuntimeEvidence)
        XCTAssertEqual(
            authority.snapshot().availability,
            .runtimeEvidenceInvalid
        )
    }

    func testImpossibleRuntimeTupleFailsClosedWithoutPublishingReady() {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )

        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: 1,
            handshake: .disconnected,
            snapshot: .available,
            session: .available,
            rendezvous: .registered
        ))

        XCTAssertEqual(authority.snapshot().failure, .invalidRuntimeEvidence)
        XCTAssertFalse(authority.snapshot().isReady)
    }

    func testProjectionViewMapsOnlyDerivedComponentEvidence() {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        let projection = HostAgentBackgroundProjectionAuthority(
            observer: { authority.acceptProjection($0) }
        )

        _ = projection.beginSession()

        XCTAssertEqual(
            authority.snapshot().runtime,
            HostAgentBackgroundRuntimeEvidence(
                projectionGeneration: 1,
                handshake: .disconnected,
                snapshot: .unavailable,
                session: .unavailable,
                rendezvous: .checking
            )
        )
        XCTAssertEqual(authority.snapshot().availability, .waitingForHandshake)
    }

    func testProductCompositionIsReadOnlyAndInertUntilExplicitActivation() {
        let observations = BackgroundHealthRecorder()

        let composition = HostAgentBackgroundRuntimeComposition.makeProduct(
            observer: { observations.append($0) }
        )

        XCTAssertEqual(composition.projectionAuthority.snapshot().phase, .idle)
        XCTAssertEqual(composition.reconnectOwner.stateSnapshot(), .idle)
        XCTAssertFalse(composition.healthAuthority.snapshot().isReady)
        XCTAssertTrue(observations.values.isEmpty)
    }

    func testLimitedSessionWithdrawsAndLaterProjectionRestoresReady() {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: .enabled,
            observeRegistration: { .enabled }
        )
        authority.acceptRuntimeEvidence(HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: 1,
            handshake: .compatible,
            snapshot: .available,
            session: .limitedSessionUnavailable,
            rendezvous: .registered
        ))

        XCTAssertEqual(authority.snapshot().availability, .sessionUnavailable)
        XCTAssertFalse(authority.snapshot().isReady)

        authority.acceptRuntimeEvidence(healthyEvidence(generation: 2))

        XCTAssertEqual(authority.snapshot().availability, .ready)
        XCTAssertTrue(authority.snapshot().isReady)
    }

    func testSourceHasNoRegistrationMutationUIOrAutomaticStart() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundHealthAuthority.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentBackgroundServiceObserver.observeRegistrationStatus"
        ))
        XCTAssertTrue(source.contains(
            "HostAgentXPCReconnectOwner.makeProduct"
        ))
        XCTAssertFalse(source.contains(".register()"))
        XCTAssertFalse(source.contains(".unregister()"))
        XCTAssertFalse(source.contains("openSystemSettingsLoginItems"))
        XCTAssertFalse(source.contains("reconnectOwner.start()"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("Keychain"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func healthyEvidence(
        generation: UInt64
    ) -> HostAgentBackgroundRuntimeEvidence {
        HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: generation,
            handshake: .compatible,
            snapshot: .available,
            session: .available,
            rendezvous: .registered
        )
    }
}

private final class BackgroundHealthRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundReadinessView] = []

    var values: [HostAgentBackgroundReadinessView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentBackgroundReadinessView) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class RegistrationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostAgentBackgroundRegistrationStatus]
    private(set) var readCount = 0

    init(_ values: [HostAgentBackgroundRegistrationStatus]) {
        self.values = values
    }

    func next() -> HostAgentBackgroundRegistrationStatus {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return values.removeFirst()
    }

    func currentReadCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }
}
