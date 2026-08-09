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

    func testTypedApprovalAndSessionRemainExplicitlyReadOnly() throws {
        let hostID = "host-a"
        let pending: [String: Any] = [
            "connectionId": "\(hostID):pending-1",
            "remoteId": "remote-1",
            "remoteName": "Mini",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "requestedAt": 40,
            "expiresAt": 80,
            "requestedCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "transport": "relay",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        ]
        let active: [String: Any] = [
            "connectionId": "\(hostID):session-1",
            "remoteId": "remote-2",
            "remoteName": "MBP",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 30,
            "initialCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
                "readClipboard", "writeClipboard",
            ],
            "activeCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "inputAvailability": "available",
            "inputUnavailableReason": NSNull(),
        ]
        let projection = try availableProjection(
            localID: "123456789",
            registrationStatus: "ready",
            lastError: nil,
            pendingApproval: pending,
            activeSession: active
        )
        let view = presentation(
            readiness: readiness(
                registration: .enabled,
                projection: projection
            ),
            projection: projection
        )

        XCTAssertEqual(view.pendingApproval?.remoteName, "Mini")
        XCTAssertEqual(
            view.pendingApproval?.requestedCapabilities,
            ["viewDisplay", "controlKeyboardMouse"]
        )
        XCTAssertEqual(view.activeSession?.remoteName, "MBP")
        XCTAssertEqual(view.activeSession?.inputAvailability, .available)
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
        let projectionSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundHomeSnapshotProjectionPolicy.swift"
            ),
            encoding: .utf8
        )
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
            ": backgroundHostApprovalHomeSnapshot("
        ))
        XCTAssertTrue(appSource.contains(
            ": backgroundHostActiveSessionHomeSnapshot("
        ))
        XCTAssertTrue(appSource.contains(
            "command: hostAgentBackgroundCommandPresentation"
        ))
        XCTAssertTrue(appSource.contains(
            "isResolving: command.activeAction == .approveIncoming"
        ))
        XCTAssertTrue(appSource.contains(
            "pendingAction: backgroundHostSessionAction("
        ))
        XCTAssertTrue(appSource.contains(
            "mediaDiagnosticText: usesLegacyHost ? hostMediaDiagnosticText() : \"\""
        ))
        XCTAssertTrue(appSource.contains(
            "enabledActions: [.approve, .reject]"
        ))
        XCTAssertEqual(appSource.components(
            separatedBy: "let availableActions = Set(command.availableActions)"
        ).count - 1, 2)
        XCTAssertFalse(appSource.contains(
            "backgroundSnapshot.allowsApprovalCommands"
        ))
        XCTAssertFalse(appSource.contains(
            "backgroundSnapshot.allowsSessionCommands"
        ))
        XCTAssertFalse(projectionSource.contains(
            "allowsApprovalCommands"
        ))
        XCTAssertFalse(projectionSource.contains(
            "allowsSessionCommands"
        ))
        XCTAssertTrue(appSource.contains(
            "backgroundHostApprovalExpiryText("
        ))
        XCTAssertFalse(homeSource.contains("var allowsCommands: Bool"))
        XCTAssertEqual(homeSource.components(
            separatedBy: "approval.enabledActions"
        ).count - 1, 4)
        XCTAssertEqual(homeSource.components(
            separatedBy: "session.enabledActions"
        ).count - 1, 3)
        XCTAssertTrue(homeSource.contains(
            "onRetryHostCommand?(retry.connectionID)"
        ))
        XCTAssertTrue(appSource.contains(
            "backgroundHostCommandRetryHomeSnapshot("
        ))
        XCTAssertFalse(appSource.contains(
            "当前版本仅可查看，操作尚未接通"
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
        lastError: String?,
        pendingApproval: Any = NSNull(),
        activeSession: Any = NSNull()
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
                lastError: lastError,
                pendingApproval: pendingApproval,
                activeSession: activeSession
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
        lastError: String?,
        pendingApproval: Any,
        activeSession: Any
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
                    "schemaVersion": 7,
                    "hostInstanceId": hostID,
                    "hostState": "ready",
                    "localId": localID,
                    "sessionAvailability": "available",
                    "sessionUnavailableReason": NSNull(),
                    "registrationStatus": registrationStatus,
                    "recoveryEpoch": 0,
                    "recoveryStatus": "running",
                    "pendingApproval": pendingApproval,
                    "activeSession": activeSession,
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
