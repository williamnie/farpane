@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundHomeSnapshotProjectionPolicyTests:
    XCTestCase
{
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testAvailableProjectionMapsOnlyReadOnlyIdentityAndPasswordPolicy()
        throws
    {
        let projection = try availableProjection(
            localID: "123456789",
            registrationStatus: "ready",
            lastError: nil
        )
        let readiness = readiness(
            registration: .enabled,
            projection: projection
        )

        XCTAssertEqual(
            presentation(readiness: readiness, projection: projection),
            HostAgentBackgroundHomeSnapshotPresentation(
                isAvailable: true,
                localID: "123456789",
                localPermanentPasswordSet: true,
                effectivePermanentPasswordSet: true,
                usingPresetPassword: false,
                permanentPasswordChangeAllowed: true,
                hasRuntimeError: false
            )
        )
    }

    func testOfflineRendezvousRetainsSnapshotWithoutClaimingCommands()
        throws
    {
        let projection = try availableProjection(
            localID: "987654321",
            registrationStatus: "degraded",
            lastError: "sanitized"
        )
        let readiness = readiness(
            registration: .enabled,
            projection: projection
        )

        XCTAssertEqual(readiness.availability, .rendezvousUnavailable)
        XCTAssertEqual(
            presentation(readiness: readiness, projection: projection),
            HostAgentBackgroundHomeSnapshotPresentation(
                isAvailable: true,
                localID: "987654321",
                localPermanentPasswordSet: true,
                effectivePermanentPasswordSet: true,
                usingPresetPassword: false,
                permanentPasswordChangeAllowed: true,
                hasRuntimeError: true
            )
        )
    }

    func testUnavailableOrIncoherentProjectionFailsClosed() throws {
        let projection = try availableProjection(
            localID: "123456789",
            registrationStatus: "ready",
            lastError: nil
        )
        let enabled = readiness(
            registration: .enabled,
            projection: projection
        )
        let requiresApproval = readiness(
            registration: .requiresApproval,
            projection: projection
        )
        let waitingAuthority = HostAgentBackgroundProjectionAuthority()
        _ = waitingAuthority.beginSession()

        XCTAssertEqual(
            HostAgentBackgroundHomeSnapshotProjectionPolicy.presentation(
                phase: nil,
                projection: projection
            ),
            .unavailable
        )
        XCTAssertEqual(
            presentation(
                readiness: requiresApproval,
                projection: projection
            ),
            .unavailable
        )
        XCTAssertEqual(
            presentation(
                readiness: enabled,
                projection: waitingAuthority.snapshot()
            ),
            .unavailable
        )
        XCTAssertEqual(
            HostAgentBackgroundHomeSnapshotProjectionPolicy.presentation(
                phase: .failed(.runtimeHealthRejected),
                projection: projection
            ),
            .unavailable
        )
    }

    func testProductSourcesCarryProjectionAndDoNotMixLegacyFields()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let activationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundActivationOwner.swift"
            ),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(activationSource.contains(
            "func projectionSnapshot()"
        ))
        XCTAssertTrue(activationSource.contains(
            "let initialProjection = runtime.projectionSnapshot()"
        ))
        XCTAssertTrue(activationSource.contains(
            "let runtimeProjection = runtime.projectionSnapshot()"
        ))
        XCTAssertEqual(activationSource.components(
            separatedBy: "projection: coherentProjection("
        ).count - 1, 2)
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundHomeSnapshotProjectionPolicy.presentation("
        ))
        XCTAssertTrue(appSource.contains(
            "localID: usesLegacyHost"
        ))
        XCTAssertTrue(appSource.contains(
            ": backgroundSnapshot.localID"
        ))
        XCTAssertTrue(appSource.contains(
            "pendingApproval: usesLegacyHost ? hostApprovalHomeSnapshot() : nil"
        ))
        XCTAssertTrue(appSource.contains(
            "activeSession: usesLegacyHost ? hostActiveSessionHomeSnapshot() : nil"
        ))
        XCTAssertTrue(appSource.contains(
            "mediaDiagnosticText: usesLegacyHost ? hostMediaDiagnosticText() : \"\""
        ))
    }

    private func presentation(
        readiness: HostAgentBackgroundReadinessView,
        projection: HostAgentBackgroundProjectionView
    ) -> HostAgentBackgroundHomeSnapshotPresentation {
        HostAgentBackgroundHomeSnapshotProjectionPolicy.presentation(
            phase: .monitoring(epoch: 1, readiness: readiness),
            projection: projection
        )
    }

    private func readiness(
        registration: HostAgentBackgroundRegistrationStatus,
        projection: HostAgentBackgroundProjectionView
    ) -> HostAgentBackgroundReadinessView {
        let authority = HostAgentBackgroundHealthAuthority(
            initialRegistration: registration,
            observeRegistration: { registration }
        )
        authority.acceptProjection(projection)
        return authority.snapshot()
    }

    private func availableProjection(
        localID: String,
        registrationStatus: String,
        lastError: String?
    ) throws -> HostAgentBackgroundProjectionView {
        let authority = HostAgentBackgroundProjectionAuthority()
        let binding = authority.beginSession()
        let hostID = "host-a"
        let peer = try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        binding.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: hostID,
                localID: localID,
                registrationStatus: registrationStatus,
                lastError: lastError
            ),
            peerIdentity: peer,
            transition: .firstObservation
        )
        return authority.snapshot()
    }

    private func snapshotResponse(
        hostID: String,
        localID: String,
        registrationStatus: String,
        lastError: String?
    ) throws -> HostAgentXPCWireSnapshotResponse {
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: [
                    "schemaVersion": 5,
                    "hostInstanceId": hostID,
                    "hostState": "ready",
                    "localId": localID,
                    "registrationStatus": registrationStatus,
                    "pendingApproval": NSNull(),
                    "activeSession": NSNull(),
                    "temporaryPasswordPresentation": [
                        "policy": "redacted",
                    ],
                    "passwordPolicy": [
                        "localPasswordSet": true,
                        "effectivePasswordSet": true,
                        "usingPresetPassword": false,
                        "changeAllowed": true,
                        "strengthPolicy": [
                            "version": 1,
                            "minimumCharacters": 6,
                            "maximumCharacters": 128,
                            "maximumUtf8Bytes": 512,
                            "rejectsControlCharacters": true,
                            "rejectsOuterWhitespace": true,
                        ],
                    ],
                    "lastError": lastError as Any? ?? NSNull(),
                    "observedAt": 10,
                ]
            )),
            eventSequence: 1,
            expectedHostInstanceID: hostID
        )
        let identity = try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        return try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: identity,
            state: state.snapshot(),
            sentAtUnixMilliseconds: 21
        )
    }
}
