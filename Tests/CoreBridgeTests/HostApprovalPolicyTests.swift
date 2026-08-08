import CoreBridge
import XCTest

final class HostApprovalPolicyTests: XCTestCase {
    func testAllProductModesExposeExactAuthenticationSemantics() throws {
        XCTAssertEqual(HostApprovalMode.allCases, [
            .manualOnly,
            .temporaryPassword,
            .permanentPassword,
            .passwordAndLocalApproval,
            .passwordOrLocalApproval,
        ])

        XCTAssertFalse(HostApprovalMode.manualOnly.permitsPasswordAuthentication)
        XCTAssertTrue(HostApprovalMode.manualOnly.permitsLocalApproval)
        XCTAssertEqual(HostApprovalMode.manualOnly.localApprovalPath, .primary)

        XCTAssertTrue(HostApprovalMode.temporaryPassword.permitsPasswordAuthentication)
        XCTAssertFalse(HostApprovalMode.temporaryPassword.permitsLocalApproval)
        XCTAssertEqual(HostApprovalMode.temporaryPassword.localApprovalPath, .prohibited)

        XCTAssertTrue(HostApprovalMode.permanentPassword.permitsPasswordAuthentication)
        XCTAssertFalse(HostApprovalMode.permanentPassword.permitsLocalApproval)
        XCTAssertEqual(HostApprovalMode.permanentPassword.localApprovalPath, .prohibited)

        XCTAssertTrue(HostApprovalMode.passwordAndLocalApproval.permitsPasswordAuthentication)
        XCTAssertTrue(HostApprovalMode.passwordAndLocalApproval.permitsLocalApproval)
        XCTAssertTrue(HostApprovalMode.passwordAndLocalApproval.requiresLocalApprovalAfterPassword)
        XCTAssertEqual(
            HostApprovalMode.passwordAndLocalApproval.localApprovalPath,
            .requiredAfterPassword
        )

        XCTAssertTrue(HostApprovalMode.passwordOrLocalApproval.permitsPasswordAuthentication)
        XCTAssertTrue(HostApprovalMode.passwordOrLocalApproval.permitsLocalApproval)
        XCTAssertFalse(HostApprovalMode.passwordOrLocalApproval.requiresLocalApprovalAfterPassword)
        XCTAssertEqual(
            HostApprovalMode.passwordOrLocalApproval.localApprovalPath,
            .alternativeToPassword
        )
    }

    func testUnattendedAccessRejectsModesThatMandateLocalPresence() throws {
        for mode in HostApprovalMode.allCases {
            let supportsUnattended = mode == .temporaryPassword
                || mode == .permanentPassword
                || mode == .passwordOrLocalApproval
            XCTAssertEqual(mode.supportsUnattendedAccess, supportsUnattended)

            if supportsUnattended {
                let policy = try HostApprovalPolicy(
                    mode: mode,
                    unattendedAccessEnabled: true
                )
                XCTAssertTrue(policy.unattendedAccessEnabled)
            } else {
                XCTAssertThrowsError(try HostApprovalPolicy(
                    mode: mode,
                    unattendedAccessEnabled: true
                )) { error in
                    XCTAssertEqual(
                        error as? HostApprovalPolicyError,
                        .unattendedAccessRequiresPasswordWithoutMandatoryLocalApproval
                    )
                }
            }
        }
    }

    func testPinnedUpstreamProjectionIsExactAndAndModeFailsClosed() throws {
        let cases: [(HostApprovalMode, String, String)] = [
            (.manualOnly, "click", "use-both-passwords"),
            (.temporaryPassword, "password", "use-temporary-password"),
            (.permanentPassword, "password", "use-permanent-password"),
            (.passwordOrLocalApproval, "both", "use-both-passwords"),
        ]

        for (mode, approveMode, verificationMethod) in cases {
            let projection = try HostApprovalPolicy(mode: mode).upstreamProjection
            XCTAssertEqual(projection.approveMode.rawValue, approveMode)
            XCTAssertEqual(projection.verificationMethod.rawValue, verificationMethod)
        }

        let twoStage = try HostApprovalPolicy(mode: .passwordAndLocalApproval)
        XCTAssertThrowsError(try twoStage.upstreamProjection) { error in
            XCTAssertEqual(
                error as? HostApprovalPolicyError,
                .nativeTwoStageGateRequired
            )
        }
    }

    func testModeWireValuesRemainCanonical() throws {
        for mode in HostApprovalMode.allCases {
            let encoded = try JSONEncoder().encode(mode)
            XCTAssertEqual(
                try JSONDecoder().decode(HostApprovalMode.self, from: encoded),
                mode
            )
            XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"\(mode.rawValue)\"")
        }
    }
}
