@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentApplicationConcurrencyObservationTests: XCTestCase {
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testCoherentProjectionDisconnectAndRecoveryUseOnePinnedScope()
        throws
    {
        let state = HostAgentApplicationConcurrencyObservationState()
        let projection = try readyProjection()

        XCTAssertNil(state.observe(
            projection: projection,
            coherentConfigRevision: nil,
            sourceToken: 1
        ))
        let ready = try XCTUnwrap(state.observe(
            projection: projection,
            coherentConfigRevision: 7,
            sourceToken: 1
        ))
        XCTAssertEqual(ready.state, .readyZeroInbound)
        XCTAssertEqual(ready.configRevision, 7)
        XCTAssertEqual(ready.sourceGeneration, 1)
        XCTAssertEqual(ready.peerIdentity.agentProcessID, 4_321)
        XCTAssertEqual(
            ready.peerIdentity.agentProcessStartIdentitySHA256,
            String(repeating: "a", count: 64)
        )

        XCTAssertNil(state.observe(
            projection: projection,
            coherentConfigRevision: nil,
            sourceToken: 2
        ))
        let disconnected = try XCTUnwrap(state.observe(
            projection: nil,
            coherentConfigRevision: nil,
            sourceToken: 3
        ))
        XCTAssertEqual(disconnected.state, .disconnected)
        XCTAssertEqual(disconnected.peerIdentity, ready.peerIdentity)
        XCTAssertEqual(disconnected.sourceGeneration, 2)
        XCTAssertNil(state.observe(
            projection: nil,
            coherentConfigRevision: nil,
            sourceToken: 3
        ))

        let recovered = try XCTUnwrap(state.observe(
            projection: projection,
            coherentConfigRevision: 7,
            sourceToken: 4
        ))
        XCTAssertEqual(recovered.state, .readyZeroInbound)
        XCTAssertEqual(recovered.sourceGeneration, 3)
        XCTAssertEqual(state.snapshot(), .init(
            acceptedSamples: 5,
            emittedObservations: 3,
            lastSourceGeneration: 3,
            scopeBound: true,
            failed: false
        ))
    }

    func testIdentityOrConfigurationDriftFailsClosed() throws {
        let state = HostAgentApplicationConcurrencyObservationState()
        XCTAssertNotNil(state.observe(
            projection: try readyProjection(),
            coherentConfigRevision: 7,
            sourceToken: 1
        ))
        XCTAssertNil(state.observe(
            projection: try readyProjection(
                processID: 4_322,
                processStartIdentitySHA256:
                    String(repeating: "b", count: 64)
            ),
            coherentConfigRevision: 7,
            sourceToken: 2
        ))
        XCTAssertTrue(state.snapshot().failed)
        XCTAssertNil(state.observe(
            projection: try readyProjection(),
            coherentConfigRevision: 7,
            sourceToken: 3
        ))

        let configDrift = HostAgentApplicationConcurrencyObservationState()
        XCTAssertNotNil(configDrift.observe(
            projection: try readyProjection(),
            coherentConfigRevision: 7,
            sourceToken: 1
        ))
        XCTAssertNil(configDrift.observe(
            projection: try readyProjection(),
            coherentConfigRevision: 8,
            sourceToken: 2
        ))
        XCTAssertTrue(configDrift.snapshot().failed)
    }

    func testSharedRuntimeStatePolicyRejectsContradictoryReadyState() {
        XCTAssertEqual(
            HostAgentConcurrencyRuntimeStatePolicy.classify(
                hostState: "ready",
                registrationStatus: "ready",
                authenticatedConnectionCount: 1,
                hasActiveSession: true
            ),
            .inboundMediaActive
        )
        XCTAssertNil(HostAgentConcurrencyRuntimeStatePolicy.classify(
            hostState: "ready",
            registrationStatus: "ready",
            authenticatedConnectionCount: 1,
            hasActiveSession: false
        ))
        XCTAssertEqual(
            HostAgentConcurrencyRuntimeStatePolicy.classify(
                hostState: "stopped",
                registrationStatus: "notStarted",
                authenticatedConnectionCount: 0,
                hasActiveSession: false
            ),
            .disconnected
        )
    }

    private func readyProjection(
        processID: Int32 = 4_321,
        processStartIdentitySHA256: String =
            String(repeating: "a", count: 64)
    ) throws -> HostAgentBackgroundProjectionView {
        let hostID = "host-a"
        let authority = HostAgentBackgroundProjectionAuthority()
        let binding = authority.beginSession()
        let peer = try HostAgentXPCSnapshotClientPeerIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID,
            agentProcessID: processID,
            agentProcessStartIdentitySHA256:
                processStartIdentitySHA256
        )
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 2,
            hostInstanceID: hostID,
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let snapshotState = HostAgentSnapshotState()
        _ = snapshotState.publish(
            try HostCoreSnapshot(rawJSON: JSONSerialization.data(
                withJSONObject: snapshotDocument(hostID: hostID)
            )),
            eventSequence: 1,
            expectedHostInstanceID: hostID
        )
        let response = try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: try HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID,
                agentProcessID: processID,
                agentProcessStartIdentitySHA256:
                    processStartIdentitySHA256
            ),
            state: snapshotState.snapshot(),
            sentAtUnixMilliseconds: 12
        )
        binding.sink.publishInitialSnapshot(
            response,
            peerIdentity: peer,
            transition: .firstObservation
        )
        return authority.snapshot()
    }

    private func snapshotDocument(hostID: String) -> [String: Any] {
        [
            "schemaVersion": 8,
            "hostInstanceId": hostID,
            "hostState": "ready",
            "localId": "123456789",
            "authenticatedConnectionCount": 0,
            "sessionAvailability": "available",
            "sessionUnavailableReason": NSNull(),
            "registrationStatus": "ready",
            "recoveryEpoch": 0,
            "recoveryStatus": "running",
            "pendingApproval": NSNull(),
            "activeSession": NSNull(),
            "temporaryPasswordPresentation": ["policy": "redacted"],
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
            "lastError": NSNull(),
            "observedAt": 10,
        ]
    }
}
