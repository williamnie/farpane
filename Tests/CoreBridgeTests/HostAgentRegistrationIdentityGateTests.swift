@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentRegistrationIdentityGateTests: XCTestCase {
    func testLocalDevelopmentEligibilityRequiresAllEvidenceInOrder() throws {
        let recorder = RegistrationIdentityRecorder()

        let status = HostAgentRegistrationIdentityGate.assess(
            launchAgentPlistData: try plistData(),
            inspectBundle: {
                recorder.append(.bundle)
                return HostAgentRegistrationBundleIdentity(
                    buildIdentifier: "202608080001"
                )
            },
            inspectCodeSignature: {
                recorder.append(.signature)
                return signatureEvidence(channel: .development)
            }
        )

        XCTAssertEqual(
            status,
            .localDevelopmentEligible(buildIdentifier: "202608080001")
        )
        XCTAssertEqual(recorder.events, [.bundle, .signature])
    }

    func testInvalidPlistStopsBeforeBundleAndSignatureInspection() {
        let recorder = RegistrationIdentityRecorder()

        let status = HostAgentRegistrationIdentityGate.assess(
            launchAgentPlistData: Data("invalid".utf8),
            inspectBundle: {
                recorder.append(.bundle)
                return HostAgentRegistrationBundleIdentity(buildIdentifier: "1")
            },
            inspectCodeSignature: {
                recorder.append(.signature)
                return signatureEvidence(channel: .development)
            }
        )

        XCTAssertEqual(status, .invalidLaunchAgent)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func testInvalidBundleStopsBeforeSignatureInspection() throws {
        let recorder = RegistrationIdentityRecorder()

        let status = HostAgentRegistrationIdentityGate.assess(
            launchAgentPlistData: try plistData(),
            inspectBundle: {
                recorder.append(.bundle)
                throw RegistrationIdentityTestError.unavailable
            },
            inspectCodeSignature: {
                recorder.append(.signature)
                return signatureEvidence(channel: .development)
            }
        )

        XCTAssertEqual(status, .invalidApplication)
        XCTAssertEqual(recorder.events, [.bundle])
    }

    func testInvalidSignatureDoesNotLeakUnderlyingError() throws {
        let status = HostAgentRegistrationIdentityGate.assess(
            launchAgentPlistData: try plistData(),
            inspectBundle: {
                HostAgentRegistrationBundleIdentity(buildIdentifier: "1")
            },
            inspectCodeSignature: {
                throw RegistrationIdentityTestError.unavailable
            }
        )

        XCTAssertEqual(status, .invalidCodeSignature)
    }

    func testRejectsMismatchedSanitizedSignatureEvidence() throws {
        let status = HostAgentRegistrationIdentityGate.assess(
            launchAgentPlistData: try plistData(),
            inspectBundle: {
                HostAgentRegistrationBundleIdentity(buildIdentifier: "1")
            },
            inspectCodeSignature: {
                HostAgentRegistrationCodeSignatureEvidence(
                    signingIdentifier: "com.example.forged",
                    teamIdentifier: "OTHERTEAM1",
                    channel: .development
                )
            }
        )

        XCTAssertEqual(status, .invalidCodeSignature)
    }

    func testDeveloperIDStillRequiresIndependentNotarizationEvidence() throws {
        let status = HostAgentRegistrationIdentityGate.assess(
            launchAgentPlistData: try plistData(),
            inspectBundle: {
                HostAgentRegistrationBundleIdentity(buildIdentifier: "release-1")
            },
            inspectCodeSignature: {
                signatureEvidence(channel: .developerID)
            }
        )

        XCTAssertEqual(
            status,
            .distributionNotarizationRequired(buildIdentifier: "release-1")
        )
    }

    func testProductAssessmentFailsClosedWithoutTheSignedAsset() {
        XCTAssertEqual(
            HostAgentRegistrationIdentityGate.assessMainBundle(),
            .invalidLaunchAgent
        )
    }

    private func signatureEvidence(
        channel: HostAgentRegistrationSigningChannel
    ) -> HostAgentRegistrationCodeSignatureEvidence {
        HostAgentRegistrationCodeSignatureEvidence(
            signingIdentifier: "io.rustdesknative.viewer",
            teamIdentifier: "3J43F8H829",
            channel: channel
        )
    }

    private func plistData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "io.rustdesknative.viewer.host-agent",
                "BundleProgram": "Contents/MacOS/RustDeskNative",
                "ProgramArguments": ["RustDeskNative", "--host-agent"],
                "MachServices": [
                    "io.rustdesknative.viewer.host-agent": true,
                ],
            ],
            format: .xml,
            options: 0
        )
    }
}

private enum RegistrationIdentityTestError: Error {
    case unavailable
}

private enum RegistrationIdentityEvent: Equatable {
    case bundle
    case signature
}

private final class RegistrationIdentityRecorder {
    private(set) var events: [RegistrationIdentityEvent] = []

    func append(_ event: RegistrationIdentityEvent) {
        events.append(event)
    }
}
