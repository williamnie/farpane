@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentLegacyHostProductEvidencePolicyTests: XCTestCase {
    func testConfirmedIdleObservationProjectsEverySignalAbsent() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: false,
                runtimeActive: false,
                clientRetained: false,
                session: .unavailable,
                mediaPipelineActive: false,
                pollerActive: false,
                runtimeQuiescenceConfirmed: true
            )
        )

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .eligible
        )
    }

    func testRunningObservationProjectsExactProductOwnership() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: true,
                runtimeActive: true,
                clientRetained: true,
                session: .available(
                    pendingApproval: true,
                    activeSession: false
                ),
                mediaPipelineActive: true,
                pollerActive: true,
                runtimeQuiescenceConfirmed: true
            )
        )

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .blocked([
                .preferenceEnabled,
                .runtimeActive,
                .clientRetained,
                .pendingApproval,
                .mediaPipelineActive,
                .pollerActive,
            ])
        )
    }

    func testRunningWithoutAuthoritativeSnapshotFailsClosed() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: true,
                runtimeActive: true,
                clientRetained: true,
                session: .unavailable,
                mediaPipelineActive: false,
                pollerActive: true,
                runtimeQuiescenceConfirmed: true
            )
        )

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .failed(.evidenceUnavailable)
        )
    }

    func testUnconfirmedCoreStopMakesRuntimeAndSessionsUnavailable() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy.evidence(
            observation(
                preferenceEnabled: false,
                runtimeActive: false,
                clientRetained: true,
                session: .unavailable,
                mediaPipelineActive: false,
                pollerActive: false,
                runtimeQuiescenceConfirmed: false
            )
        )

        XCTAssertEqual(evidence.runtimeActive, .unavailable)
        XCTAssertEqual(evidence.pendingApproval, .unavailable)
        XCTAssertEqual(evidence.activeSession, .unavailable)
        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .failed(.evidenceUnavailable)
        )
    }

    func testOffMainFallbackMakesEverySignalUnavailable() {
        let evidence = HostAgentLegacyHostProductEvidencePolicy
            .unavailableEvidence

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .failed(.evidenceUnavailable)
        )
        XCTAssertEqual(evidence.preferenceEnabled, .unavailable)
        XCTAssertEqual(evidence.clientRetained, .unavailable)
        XCTAssertEqual(evidence.mediaPipelineActive, .unavailable)
        XCTAssertEqual(evidence.pollerActive, .unavailable)
    }

    func testProductAdapterUsesRealStateAndRemainsInert() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        let homeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HomeView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains(
            "private lazy var hostAgentLegacyMigrationCoordinator"
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentLegacyHostProductEvidencePolicy.evidence("
        ))
        XCTAssertTrue(appSource.contains(
            "runtimeQuiescenceConfirmed: hostRuntimeQuiescenceConfirmed"
        ))
        XCTAssertTrue(appSource.contains(
            "session: hostSnapshot.map"
        ))
        XCTAssertTrue(appSource.contains("guard Thread.isMainThread else"))
        XCTAssertTrue(appSource.contains("MainActorBackport.assumeIsolated"))
        XCTAssertTrue(appSource.contains(
            "private func requestLegacyHostQuiescence()"
        ))
        XCTAssertTrue(appSource.contains(
            "releaseClient: true"
        ))
        XCTAssertTrue(appSource.contains(
            "hostSnapshot?.pendingApproval == nil"
        ))
        XCTAssertTrue(appSource.contains(
            "hostSnapshot?.activeSession == nil"
        ))

        XCTAssertEqual(
            appSource.components(
                separatedBy: "prepareLegacyHostForBackgroundRegistration()"
            ).count - 1,
            4
        )
        XCTAssertFalse(homeSource.contains(
            "prepareLegacyHostForBackgroundRegistration"
        ))
        XCTAssertTrue(appSource.contains(
            "private lazy var hostAgentBackgroundRegistrationSheetDriver"
        ))
        XCTAssertEqual(appSource.components(
            separatedBy: "hostAgentBackgroundRegistrationSheetDriver.begin("
        ).count - 1, 1)
    }

    func testStopFailureRemainsUnconfirmedAndBlocksDependentStarts() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "private var hostRuntimeQuiescenceConfirmed = true"
        ))
        XCTAssertTrue(source.contains(
            "guard hostRuntimeQuiescenceConfirmed else"
        ))
        XCTAssertTrue(source.contains(
            "hostRuntimeQuiescenceConfirmed = stopSucceeded"
        ))
        XCTAssertTrue(source.contains(
            "if releaseClient, stopSucceeded"
        ))
        XCTAssertTrue(source.contains("return stopSucceeded"))
        XCTAssertTrue(source.contains(
            "guard stopHostMode(\n"
                + "                preservePreference: true,\n"
                + "                reason: .userRequest,\n"
                + "                releaseClient: true\n"
                + "            ) else"
        ))
        XCTAssertTrue(source.contains(
            "if stopHostMode(\n"
                + "                    preservePreference: true,\n"
                + "                    reason: .userRequest\n"
                + "                ) {\n"
                + "                    startHostMode()\n"
                + "                }"
        ))
    }
}

private func observation(
    preferenceEnabled: Bool,
    runtimeActive: Bool,
    clientRetained: Bool,
    session: HostAgentLegacyHostSessionObservation,
    mediaPipelineActive: Bool,
    pollerActive: Bool,
    runtimeQuiescenceConfirmed: Bool
) -> HostAgentLegacyHostProductObservation {
    HostAgentLegacyHostProductObservation(
        preferenceEnabled: preferenceEnabled,
        runtimeActive: runtimeActive,
        clientRetained: clientRetained,
        session: session,
        mediaPipelineActive: mediaPipelineActive,
        pollerActive: pollerActive,
        runtimeQuiescenceConfirmed: runtimeQuiescenceConfirmed
    )
}
