@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentRegistrationBundlePreflightTests: XCTestCase {
    func testAcceptsOnlyTheFixedProductBundleIdentity() throws {
        XCTAssertEqual(
            try HostAgentRegistrationBundlePreflight.validate(
                bundleURL: productURL,
                resolvedBundleURL: productURL,
                infoDictionary: validInfoDictionary
            ),
            HostAgentRegistrationBundleIdentity(buildIdentifier: "202608080001")
        )
    }

    func testRejectsRelocatedAliasedAndNonLocalBundles() throws {
        let invalidLocations = [
            URL(fileURLWithPath: "/Users/test/Applications/FarPane.app", isDirectory: true),
            URL(string: "https://example.invalid/Applications/FarPane.app")!,
        ]
        for location in invalidLocations {
            XCTAssertThrowsError(
                try HostAgentRegistrationBundlePreflight.validate(
                    bundleURL: location,
                    resolvedBundleURL: location,
                    infoDictionary: validInfoDictionary
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentRegistrationBundlePreflightError,
                    .invalidLocation
                )
            }
        }

        XCTAssertThrowsError(
            try HostAgentRegistrationBundlePreflight.validate(
                bundleURL: productURL,
                resolvedBundleURL: URL(
                    fileURLWithPath: "/private/tmp/FarPane.app",
                    isDirectory: true
                ),
                infoDictionary: validInfoDictionary
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentRegistrationBundlePreflightError,
                .invalidLocation
            )
        }
    }

    func testRejectsEveryMismatchedBundleMetadataField() throws {
        let cases: [(String, Any, HostAgentRegistrationBundlePreflightError)] = [
            ("CFBundleIdentifier", "com.example.farpane", .invalidBundleIdentifier),
            ("CFBundlePackageType", "BNDL", .invalidPackageType),
            ("CFBundleExecutable", "FarPane", .invalidExecutable),
        ]

        for (key, value, expectedError) in cases {
            var infoDictionary = validInfoDictionary
            infoDictionary[key] = value
            XCTAssertThrowsError(
                try HostAgentRegistrationBundlePreflight.validate(
                    bundleURL: productURL,
                    resolvedBundleURL: productURL,
                    infoDictionary: infoDictionary
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentRegistrationBundlePreflightError,
                    expectedError
                )
            }
        }
    }

    func testBuildIdentifierUsesTheSameBoundedTokenContractAsAgentBootstrap() throws {
        var validInfoDictionary = validInfoDictionary
        validInfoDictionary["CFBundleVersion"] = "build+42"
        XCTAssertEqual(
            try HostAgentRegistrationBundlePreflight.validate(
                bundleURL: productURL,
                resolvedBundleURL: productURL,
                infoDictionary: validInfoDictionary
            ).buildIdentifier,
            "build+42"
        )

        let invalidBuildIdentifiers: [Any?] = [
            nil,
            NSNumber(value: 42),
            "",
            " 42",
            "build/42",
            String(repeating: "a", count: 129),
        ]

        for buildIdentifier in invalidBuildIdentifiers {
            var infoDictionary = validInfoDictionary
            infoDictionary["CFBundleVersion"] = buildIdentifier
            XCTAssertThrowsError(
                try HostAgentRegistrationBundlePreflight.validate(
                    bundleURL: productURL,
                    resolvedBundleURL: productURL,
                    infoDictionary: infoDictionary
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentRegistrationBundlePreflightError,
                    .invalidBuildIdentifier
                )
            }
        }
    }

    func testProductInspectionFailsClosedOutsideApplicationsWithoutMutation() {
        XCTAssertThrowsError(
            try HostAgentRegistrationBundlePreflight.inspectMainBundle()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentRegistrationBundlePreflightError,
                .invalidLocation
            )
        }
    }

    private var productURL: URL {
        URL(fileURLWithPath: "/Applications/FarPane.app", isDirectory: true)
    }

    private var validInfoDictionary: [String: Any] {
        [
            "CFBundleIdentifier": "io.rustdesknative.viewer",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "RustDeskNative",
            "CFBundleVersion": "202608080001",
        ]
    }
}
