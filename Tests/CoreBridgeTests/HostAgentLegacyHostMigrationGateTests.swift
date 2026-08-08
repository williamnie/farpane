@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentLegacyHostMigrationGateTests: XCTestCase {
    func testFullyQuiescentLegacyHostIsEligible() {
        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(.quiescent),
            .eligible
        )
    }

    func testEveryUnavailableSignalFailsClosed() {
        for field in LegacyEvidenceField.allCases {
            let evidence = HostAgentLegacyHostMigrationEvidence.quiescent
                .with(field, .unavailable)
            XCTAssertEqual(
                HostAgentLegacyHostMigrationGate.assess(evidence),
                .failed(.evidenceUnavailable)
            )
        }
    }

    func testImpossibleRuntimeTuplesFailClosed() {
        let impossibleEvidence: [HostAgentLegacyHostMigrationEvidence] = [
            .quiescent.with(.pendingApproval, .present),
            .quiescent.with(.activeSession, .present),
            .quiescent.with(.mediaPipelineActive, .present),
            .quiescent.with(.pollerActive, .present),
            .quiescent.with(.runtimeActive, .present),
        ]

        for evidence in impossibleEvidence {
            XCTAssertEqual(
                HostAgentLegacyHostMigrationGate.assess(evidence),
                .failed(.inconsistentEvidence)
            )
        }
    }

    func testActiveLegacyHostReturnsEveryExactBlocker() {
        let evidence = HostAgentLegacyHostMigrationEvidence(
            preferenceEnabled: .present,
            runtimeActive: .present,
            clientRetained: .present,
            pendingApproval: .present,
            activeSession: .present,
            mediaPipelineActive: .present,
            pollerActive: .present
        )

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .blocked([
                .preferenceEnabled,
                .runtimeActive,
                .clientRetained,
                .pendingApproval,
                .activeSession,
                .mediaPipelineActive,
                .pollerActive,
            ])
        )
    }

    func testRetainedClientAloneBlocksMigration() {
        let evidence = HostAgentLegacyHostMigrationEvidence.quiescent
            .with(.clientRetained, .present)

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .blocked([.clientRetained])
        )
    }

    func testEnabledPreferenceAloneBlocksMigration() {
        let evidence = HostAgentLegacyHostMigrationEvidence.quiescent
            .with(.preferenceEnabled, .present)

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .blocked([.preferenceEnabled])
        )
    }

    func testDisabledPreferenceDuringRunningHostIsBlockedNotInconsistent() {
        let evidence = HostAgentLegacyHostMigrationEvidence.quiescent
            .with(.runtimeActive, .present)
            .with(.clientRetained, .present)
            .with(.pollerActive, .present)

        XCTAssertEqual(
            HostAgentLegacyHostMigrationGate.assess(evidence),
            .blocked([.runtimeActive, .clientRetained, .pollerActive])
        )
    }

    func testGateSourceHasNoMutationOrProductFrameworkAuthority() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentLegacyHostMigrationGate.swift"
            ),
            encoding: .utf8
        )

        for forbidden in [
            "import AppKit",
            "import ServiceManagement",
            "UserDefaults",
            "HostControlClient",
            "SMAppService",
            ".register()",
            ".unregister()",
            "stopHostMode",
            "startHostMode",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}

private enum LegacyEvidenceField: CaseIterable {
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

    func with(
        _ field: LegacyEvidenceField,
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
