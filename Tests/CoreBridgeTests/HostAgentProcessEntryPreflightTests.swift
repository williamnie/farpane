import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentProcessEntryPreflightTests: XCTestCase {
    func testAcceptsOnlyExactLaunchAgentOrInstalledExecutableInvocation() {
        for executable in [
            "FarPaneHostAgent", "/Applications/FarPane.app/Contents/MacOS/FarPaneHostAgent",
        ] {
            let identityReads = EntryIdentityReadCounter()

            XCTAssertEqual(
                HostAgentProcessEntryPreflight.assess(
                    arguments: [executable, "--host-agent"],
                    assessIdentity: {
                        identityReads.record()
                        return .localDevelopmentEligible(buildIdentifier: "202608090001")
                    }),
                .eligible(
                    HostAgentProcessEntryEligibility(
                        buildIdentifier: "202608090001", signingChannel: .localDevelopment)))
            XCTAssertEqual(identityReads.count, 1)
        }
    }

    func testRejectsMissingExtraAndLookalikeArgumentsBeforeIdentityRead() {
        let invalidArguments = [
            ["FarPaneHostAgent"], ["FarPaneHostAgent", "--host-agent=false"],
            ["FarPaneHostAgent", "--host-agent", "--fixture"],
            ["FarPaneHostAgent", "--fixture", "sample", "--host-agent"],
            ["FarPaneHostAgent", "--host-agent", "--host-agent"],
            ["FarPaneHostAgent", "--host-agent\u{0}"],
        ]

        for arguments in invalidArguments {
            let identityReads = EntryIdentityReadCounter()
            XCTAssertEqual(
                HostAgentProcessEntryPreflight.assess(
                    arguments: arguments,
                    assessIdentity: {
                        identityReads.record()
                        return .localDevelopmentEligible(buildIdentifier: "1")
                    }), .rejected(.invalidInvocation))
            XCTAssertEqual(identityReads.count, 0)
        }
    }

    func testRejectsRelocatedRelativeAndLookalikeExecutableArguments() {
        let invalidExecutables = [
            "FarPane", "RustDeskNative", "./FarPaneHostAgent", "/tmp/FarPaneHostAgent",
            "/Applications/FarPane.app/Contents/MacOS/FarPaneHostAgent-copy",
            "/Applications/FarPane.app/Contents/MacOS/../MacOS/FarPaneHostAgent",
            "/Users/test/Applications/FarPane.app/Contents/MacOS/FarPaneHostAgent",
        ]

        for executable in invalidExecutables {
            XCTAssertEqual(
                HostAgentProcessEntryPreflight.assess(
                    arguments: [executable, "--host-agent"],
                    assessIdentity: { .localDevelopmentEligible(buildIdentifier: "1") }),
                .rejected(.invalidInvocation))
        }
    }

    func testMapsEveryInvalidIdentityStageToSanitizedEntryFailure() {
        let cases: [(HostAgentRegistrationIdentityStatus, HostAgentProcessEntryFailure)] = [
            (.invalidLaunchAgent, .invalidLaunchAgent), (.invalidApplication, .invalidApplication),
            (.invalidCodeSignature, .invalidCodeSignature),
        ]

        for (identity, failure) in cases {
            XCTAssertEqual(
                HostAgentProcessEntryPreflight.assess(
                    arguments: ["FarPaneHostAgent", "--host-agent"], assessIdentity: { identity }),
                .rejected(failure))
        }
    }

    func testDeveloperIDCannotStartUntilNotarizationEvidenceExists() {
        XCTAssertEqual(
            HostAgentProcessEntryPreflight.assess(
                arguments: ["FarPaneHostAgent", "--host-agent"],
                assessIdentity: { .distributionNotarizationRequired(buildIdentifier: "release-1") }),
            .rejected(.distributionNotarizationRequired))
    }

    func testForgedInvalidBuildIdentifierFailsClosed() {
        for identity in [
            HostAgentRegistrationIdentityStatus.localDevelopmentEligible(buildIdentifier: ""),
            .localDevelopmentEligible(buildIdentifier: "bad/build"),
            .distributionNotarizationRequired(buildIdentifier: " bad"),
        ] {
            XCTAssertEqual(
                HostAgentProcessEntryPreflight.assess(
                    arguments: ["FarPaneHostAgent", "--host-agent"], assessIdentity: { identity }),
                .rejected(.invalidApplication))
        }
    }

    func testProductAssessmentUsesCommandLineThenFixedIdentityGate() {
        XCTAssertEqual(
            HostAgentProcessEntryPreflight.assessMainProcess(), .rejected(.invalidInvocation))
    }

}

private final class EntryIdentityReadCounter {
    private(set) var count = 0

    func record() { count += 1 }
}
