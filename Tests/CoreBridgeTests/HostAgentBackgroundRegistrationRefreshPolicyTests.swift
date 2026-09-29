import XCTest

@testable import CoreBridge

final class HostAgentBackgroundRegistrationRefreshPolicyTests: XCTestCase {
    func testEnabledRegistrationRefreshesMissingOrOlderRegisteredBuild() {
        for registeredBuild in [nil, "202608211332"] {
            XCTAssertEqual(
                HostAgentBackgroundRegistrationRefreshPolicy.decision(
                    registration: .enabled, currentBuildIdentifier: "202608252205",
                    registeredBuildIdentifier: registeredBuild, alreadyAttempted: false),
                .refresh(buildIdentifier: "202608252205"))
        }
    }

    func testMatchingBuildAndRepeatedAttemptRemainInert() {
        XCTAssertEqual(
            HostAgentBackgroundRegistrationRefreshPolicy.decision(
                registration: .enabled, currentBuildIdentifier: "202608252205",
                registeredBuildIdentifier: "202608252205", alreadyAttempted: false), .noAction)
        XCTAssertEqual(
            HostAgentBackgroundRegistrationRefreshPolicy.decision(
                registration: .enabled, currentBuildIdentifier: "202608252205",
                registeredBuildIdentifier: "202608211332", alreadyAttempted: true), .noAction)
    }

    func testPendingAndInvalidBuildNeverMutateRegistration() {
        let cases: [(HostAgentBackgroundRegistrationStatus, String?)] = [
            (.notRegistered, "202608252205"), (.requiresApproval, "202608252205"),
            (.serviceUnavailable, "202608252205"), (.enabled, nil), (.enabled, "bad build id"),
        ]

        for (registration, buildIdentifier) in cases {
            XCTAssertEqual(
                HostAgentBackgroundRegistrationRefreshPolicy.decision(
                    registration: registration, currentBuildIdentifier: buildIdentifier,
                    registeredBuildIdentifier: "older", alreadyAttempted: false), .noAction)
        }
    }

}
