import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentLegacyHostProductEvidencePolicyTests: XCTestCase {
    func testConfirmedIdleObservationProjectsEverySignalAbsent() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: false, runtimeActive: false, clientRetained: false,
                session: .unavailable, mediaPipelineActive: false, pollerActive: false,
                runtimeQuiescenceConfirmed: true))

        XCTAssertEqual(HostAgentLegacyHostMigrationGate.assess(evidence), .eligible)
    }

    func testRunningObservationProjectsExactProductOwnership() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: true, runtimeActive: true, clientRetained: true,
                session: .available(pendingApproval: true, activeSession: false),
                mediaPipelineActive: true, pollerActive: true, runtimeQuiescenceConfirmed: true))

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .blocked([
                .preferenceEnabled, .runtimeActive, .clientRetained, .pendingApproval,
                .mediaPipelineActive, .pollerActive,
            ]))
    }

    func testRunningWithoutAuthoritativeSnapshotFailsClosed() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: true, runtimeActive: true, clientRetained: true,
                session: .unavailable, mediaPipelineActive: false, pollerActive: true,
                runtimeQuiescenceConfirmed: true))

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence), .failed(.evidenceUnavailable))
    }

    func testUnconfirmedCoreStopMakesRuntimeAndSessionsUnavailable() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: false, runtimeActive: false, clientRetained: true,
                session: .unavailable, mediaPipelineActive: false, pollerActive: false,
                runtimeQuiescenceConfirmed: false))

        XCTAssertEqual(evidence.runtimeActive, .unavailable)
        XCTAssertEqual(evidence.pendingApproval, .unavailable)
        XCTAssertEqual(evidence.activeSession, .unavailable)
        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence), .failed(.evidenceUnavailable))
    }

    func testOffMainFallbackMakesEverySignalUnavailable() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.unavailableEvidence

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence), .failed(.evidenceUnavailable))
        XCTAssertEqual(evidence.preferenceEnabled, .unavailable)
        XCTAssertEqual(evidence.clientRetained, .unavailable)
        XCTAssertEqual(evidence.mediaPipelineActive, .unavailable)
        XCTAssertEqual(evidence.pollerActive, .unavailable)
    }

}

private func observation(
    preferenceEnabled: Bool, runtimeActive: Bool, clientRetained: Bool,
    session: HostAgentLegacyHostSessionObservation, mediaPipelineActive: Bool, pollerActive: Bool,
    runtimeQuiescenceConfirmed: Bool
) -> HostAgentLegacyHostProductObservation {
    HostAgentLegacyHostProductObservation(
        preferenceEnabled: preferenceEnabled, runtimeActive: runtimeActive,
        clientRetained: clientRetained, session: session, mediaPipelineActive: mediaPipelineActive,
        pollerActive: pollerActive, runtimeQuiescenceConfirmed: runtimeQuiescenceConfirmed)
}
