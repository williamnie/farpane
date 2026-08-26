@testable import CoreBridge
import XCTest

final class HostAgentBackgroundRegistrationRefreshPolicyTests: XCTestCase {
    func testEnabledRegistrationRefreshesMissingOrOlderRegisteredBuild() {
        for registeredBuild in [nil, "202608211332"] {
            XCTAssertEqual(
                HostAgentBackgroundRegistrationRefreshPolicy.decision(
                    registration: .enabled,
                    currentBuildIdentifier: "202608252205",
                    registeredBuildIdentifier: registeredBuild,
                    alreadyAttempted: false
                ),
                .refresh(buildIdentifier: "202608252205")
            )
        }
    }

    func testMatchingBuildAndRepeatedAttemptRemainInert() {
        XCTAssertEqual(
            HostAgentBackgroundRegistrationRefreshPolicy.decision(
                registration: .enabled,
                currentBuildIdentifier: "202608252205",
                registeredBuildIdentifier: "202608252205",
                alreadyAttempted: false
            ),
            .noAction
        )
        XCTAssertEqual(
            HostAgentBackgroundRegistrationRefreshPolicy.decision(
                registration: .enabled,
                currentBuildIdentifier: "202608252205",
                registeredBuildIdentifier: "202608211332",
                alreadyAttempted: true
            ),
            .noAction
        )
    }

    func testPendingAndInvalidBuildNeverMutateRegistration() {
        let cases: [(
            HostAgentBackgroundRegistrationStatus,
            String?
        )] = [
            (.notRegistered, "202608252205"),
            (.requiresApproval, "202608252205"),
            (.serviceUnavailable, "202608252205"),
            (.enabled, nil),
            (.enabled, "bad build id"),
        ]

        for (registration, buildIdentifier) in cases {
            XCTAssertEqual(
                HostAgentBackgroundRegistrationRefreshPolicy.decision(
                    registration: registration,
                    currentBuildIdentifier: buildIdentifier,
                    registeredBuildIdentifier: "older",
                    alreadyAttempted: false
                ),
                .noAction
            )
        }
    }

    func testProductWiringPersistsOnlySuccessfulCurrentBuildRefresh() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = try String(
            contentsOf: repository.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )

        for marker in [
            "farpane.host.agentRegistrationBuildID",
            "refreshRegisteredHostAgentForCurrentBuildIfNeeded()",
            ".unregisterBackgroundAgent",
            ".registerBackgroundAgent",
            "recordCurrentHostAgentRegistrationBuildIfEnabled()",
            "后台组件升级刷新失败",
        ] {
            XCTAssertTrue(app.contains(marker), marker)
        }
    }
}
