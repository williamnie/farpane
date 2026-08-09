@testable import CoreBridge
import XCTest

final class HostAgentBackgroundReadinessPolicyTests: XCTestCase {
    func testRegistrationStateCannotBeOverriddenByHealthyRuntimeSignals() {
        XCTAssertEqual(
            health(registration: .notRegistered).availability,
            .notRegistered
        )
        XCTAssertEqual(
            health(registration: .requiresApproval).availability,
            .requiresApproval
        )
        XCTAssertEqual(
            health(registration: .serviceUnavailable).availability,
            .serviceUnavailable
        )
    }

    func testEnabledRegistrationStillWaitsForAuthenticatedHandshake() {
        XCTAssertEqual(
            health(handshake: .disconnected).availability,
            .waitingForHandshake
        )
    }

    func testIncompatibleHandshakeFailsBeforeSnapshotAndRendezvousHealth() {
        XCTAssertEqual(
            health(handshake: .incompatible).availability,
            .incompatible
        )
    }

    func testCompatibleHandshakeStillRequiresSnapshotAndRendezvous() {
        XCTAssertEqual(
            health(snapshot: .unavailable).availability,
            .waitingForSnapshot
        )
        XCTAssertEqual(
            health(rendezvous: .checking).availability,
            .rendezvousUnavailable
        )
        XCTAssertEqual(
            health(rendezvous: .offline).availability,
            .rendezvousUnavailable
        )
    }

    func testLimitedSessionWithdrawsReadyBeforeRendezvousHealth() {
        let snapshot = health(
            session: .limitedSessionUnavailable,
            rendezvous: .registered
        )

        XCTAssertEqual(snapshot.availability, .sessionUnavailable)
        XCTAssertFalse(snapshot.isReady)
    }

    func testSnapshotAndSessionEvidenceMustBeConsistent() {
        XCTAssertEqual(
            health(
                snapshot: .unavailable,
                session: .available
            ).availability,
            .runtimeEvidenceInvalid
        )
        XCTAssertEqual(
            health(
                snapshot: .available,
                session: .unavailable
            ).availability,
            .runtimeEvidenceInvalid
        )
    }

    func testReadyRequiresEveryIndependentComponentToBeHealthy() {
        let snapshot = health()

        XCTAssertEqual(snapshot.availability, .ready)
        XCTAssertTrue(snapshot.isReady)
    }

    private func health(
        registration: HostAgentBackgroundRegistrationStatus = .enabled,
        handshake: HostAgentBackgroundHandshakeStatus = .compatible,
        snapshot: HostAgentBackgroundSnapshotStatus = .available,
        session: HostAgentBackgroundSessionStatus? = nil,
        rendezvous: HostAgentBackgroundRendezvousStatus = .registered
    ) -> HostAgentBackgroundComponentHealth {
        HostAgentBackgroundComponentHealth(
            registration: registration,
            handshake: handshake,
            snapshot: snapshot,
            session: session ?? (
                snapshot == .available ? .available : .unavailable
            ),
            rendezvous: rendezvous
        )
    }
}
