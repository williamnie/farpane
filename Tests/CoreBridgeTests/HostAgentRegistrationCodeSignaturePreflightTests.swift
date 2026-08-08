@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentRegistrationCodeSignaturePreflightTests: XCTestCase {
    func testUsesOneFixedProductSigningAuthority() {
        XCTAssertEqual(
            HostAgentRegistrationCodeSignaturePreflight.expectedSigningIdentifier,
            "io.rustdesknative.viewer"
        )
        XCTAssertEqual(
            HostAgentRegistrationCodeSignaturePreflight.expectedTeamIdentifier,
            "3J43F8H829"
        )
    }

    func testInstalledProductHasAValidSupportedSigningChannel() throws {
        let productURL = URL(
            fileURLWithPath: "/Applications/FarPane.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: productURL.path) else {
            throw XCTSkip("installed FarPane product is unavailable")
        }

        let evidence = try HostAgentRegistrationCodeSignaturePreflight
            .inspectValidatedBundle(at: productURL)

        XCTAssertEqual(evidence.signingIdentifier, "io.rustdesknative.viewer")
        XCTAssertEqual(evidence.teamIdentifier, "3J43F8H829")
        XCTAssertTrue(
            evidence.channel == .development
                || evidence.channel == .developerID
        )
    }

    func testRejectsAValidAppleSignedBundleFromAnotherAuthority() throws {
        let systemAppURL = URL(
            fileURLWithPath: "/System/Applications/Calculator.app",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: systemAppURL.path) else {
            throw XCTSkip("system comparison app is unavailable")
        }

        XCTAssertThrowsError(
            try HostAgentRegistrationCodeSignaturePreflight
                .inspectValidatedBundle(at: systemAppURL)
        ) { error in
            XCTAssertEqual(
                error as? HostAgentRegistrationCodeSignaturePreflightError,
                .signatureMismatch
            )
        }
    }

    func testProductInspectionCannotBypassBundleIdentityPreflight() {
        XCTAssertThrowsError(
            try HostAgentRegistrationCodeSignaturePreflight.inspectMainBundle()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentRegistrationCodeSignaturePreflightError,
                .invalidBundleIdentity
            )
        }
    }
}
