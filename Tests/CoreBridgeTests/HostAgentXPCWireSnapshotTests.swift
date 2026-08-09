@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCWireSnapshotTests: XCTestCase {
    private let requestID = "287fd5f2-98b7-4183-ac81-6973cef9a610"
    private let bootID = "151db9a9-7dd3-4fea-93af-1b6c10840676"

    func testAvailableProjectionRoundTripsAsCorrelatedSnapshotFirstDocument() throws {
        let request = try makeRequest()
        let identity = try makeIdentity()
        let state = HostAgentSnapshotState()
        XCTAssertEqual(
            state.publish(
                try coreSnapshot(host: "host-a", observedAt: 42),
                eventSequence: 7,
                expectedHostInstanceID: "host-a"
            ),
            .published(generation: 1)
        )

        let response = try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: identity,
            state: state.snapshot(),
            sentAtUnixMilliseconds: 50
        )
        let decoded = try HostAgentXPCWireSnapshotResponse.decode(
            response.encoded()
        )

        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.requestID, requestID)
        XCTAssertEqual(decoded.wireVersion, 1)
        XCTAssertEqual(decoded.hostInstanceID, "host-a")
        XCTAssertEqual(decoded.agentBootID, bootID)
        XCTAssertEqual(decoded.lastEventID, 7)
        XCTAssertGreaterThan(decoded.payloadLength, 0)
        XCTAssertEqual(decoded.snapshot.schemaVersion, 6)
        XCTAssertEqual(decoded.snapshot.hostState, "ready")
        XCTAssertEqual(decoded.snapshot.localID, "123456789")
        XCTAssertEqual(decoded.snapshot.registrationStatus, "ready")
        XCTAssertEqual(decoded.snapshot.recoveryEpoch, 0)
        XCTAssertEqual(decoded.snapshot.recoveryStatus, .running)
        XCTAssertEqual(decoded.snapshot.temporaryPasswordPolicy, "redacted")
        XCTAssertNil(decoded.snapshot.pendingApproval)
        XCTAssertNil(decoded.snapshot.activeSession)
        XCTAssertNil(decoded.snapshot.lastError)
        XCTAssertEqual(decoded.snapshot.observedAt, 42)
        XCTAssertEqual(decoded.evaluate(for: request), .correlated)

        let staleIdentityRequest = try HostAgentXPCWireSnapshotRequest(
            requestID: requestID,
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            sentAtUnixMilliseconds: 51
        )
        XCTAssertEqual(
            decoded.evaluate(for: staleIdentityRequest),
            .invalidResponse
        )
    }

    func testWireProjectionNeverContainsOneShotPasswordOrRawSnapshot() throws {
        let secret = "must-never-cross-xpc"
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(
                host: "host-a",
                observedAt: 42,
                revealedPassword: secret
            ),
            eventSequence: 1,
            expectedHostInstanceID: "host-a"
        )
        let response = try HostAgentXPCWireSnapshotResponse.make(
            for: makeRequest(),
            identity: makeIdentity(),
            state: state.snapshot(),
            sentAtUnixMilliseconds: 50
        )
        let encoded = try response.encoded()
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains("rawJSON"))
        XCTAssertFalse(text.contains("revealedTemporaryPassword"))
        XCTAssertFalse(text.contains("temporaryPasswordPresentation"))
        XCTAssertTrue(text.contains("\"temporaryPasswordPolicy\":\"redacted\""))
    }

    func testResponseFactoryFailsClosedWithoutMatchingAvailableAuthority() throws {
        let request = try makeRequest()
        let identity = try makeIdentity()
        let waiting = HostAgentSnapshotState()

        XCTAssertThrowsError(try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: identity,
            state: waiting.snapshot(),
            sentAtUnixMilliseconds: 2
        )) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireSnapshotDocumentError,
                .snapshotUnavailable
            )
        }

        let available = HostAgentSnapshotState()
        _ = available.publish(
            try coreSnapshot(host: "host-b", observedAt: 1),
            eventSequence: 1,
            expectedHostInstanceID: "host-b"
        )
        XCTAssertThrowsError(try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: identity,
            state: available.snapshot(),
            sentAtUnixMilliseconds: 2
        ))

        let wrongBootRequest = try HostAgentXPCWireSnapshotRequest(
            requestID: requestID,
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            sentAtUnixMilliseconds: 1
        )
        XCTAssertThrowsError(try HostAgentXPCWireSnapshotResponse.make(
            for: wrongBootRequest,
            identity: identity,
            state: available.snapshot(),
            sentAtUnixMilliseconds: 2
        ))
    }

    func testRequestDecoderRejectsUnknownMalformedAndUnboundedDocuments() throws {
        let valid = requestDocument()
        let malformed: [[String: Any]] = [
            merging(valid, ["unknown": true]),
            removing(valid, "requestId"),
            merging(valid, ["schemaVersion": 2]),
            merging(valid, ["wireVersion": 2]),
            merging(valid, ["wireVersion": true]),
            merging(valid, ["messageType": "command"]),
            merging(valid, ["requestId": "NOT-A-CANONICAL-UUID"]),
            merging(valid, ["hostInstanceId": "host/invalid"]),
            merging(valid, ["agentBootId": "not-a-uuid"]),
            merging(valid, ["sentAtUnixMilliseconds": false]),
            merging(valid, ["sentAtUnixMilliseconds": 0]),
            merging(valid, ["payloadLength": 1]),
            merging(valid, ["payload": ["unexpected": true]]),
        ]

        for document in malformed {
            XCTAssertThrowsError(
                try HostAgentXPCWireSnapshotRequest.decode(data(document))
            )
        }
        XCTAssertThrowsError(
            try HostAgentXPCWireSnapshotRequest.decode(Data())
        )
        XCTAssertThrowsError(
            try HostAgentXPCWireSnapshotRequest.decode(Data(
                repeating: 0x20,
                count: HostAgentXPCWireSnapshotContract.maximumDocumentBytes + 1
            ))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireSnapshotDocumentError,
                .documentTooLarge
            )
        }
    }

    func testResponseDecoderRejectsInvalidEnvelopeAndSnapshotShape() throws {
        let valid = try responseDocument()
        let validPayload = valid["payload"] as! [String: Any]
        let validSnapshot = validPayload["snapshot"] as! [String: Any]
        let validPasswordPolicy = validSnapshot["passwordPolicy"]
            as! [String: Any]
        let malformed: [[String: Any]] = [
            merging(valid, ["unknown": true]),
            merging(valid, ["messageType": "snapshotRequest"]),
            try replacingPayload(valid, ["lastEventId": true]),
            try replacingPayload(valid, ["lastEventId": 1.5]),
            merging(valid, ["hostInstanceId": "host/invalid"]),
            merging(valid, ["wireVersion": 2]),
            merging(valid, ["payloadLength": 1]),
            try replacingPayload(valid, ["snapshot": merging(
                validSnapshot,
                ["unknown": true]
            )]),
            try replacingPayload(valid, ["snapshot": merging(
                validSnapshot,
                ["temporaryPasswordPolicy": "revealed"]
            )]),
            try replacingPayload(valid, ["snapshot": merging(
                validSnapshot,
                ["observedAt": false]
            )]),
            try replacingPayload(valid, ["snapshot": merging(
                validSnapshot,
                ["recoveryStatus": "suspended"]
            )]),
            try replacingPayload(valid, ["snapshot": merging(
                validSnapshot,
                ["passwordPolicy": merging(
                    validPasswordPolicy,
                    ["localPasswordSet": 1]
                )]
            )]),
        ]

        for document in malformed {
            XCTAssertThrowsError(
                try HostAgentXPCWireSnapshotResponse.decode(data(document))
            )
        }
    }

    func testTypedApprovalAndSessionPayloadsPreserveOnlyValidatedFields() throws {
        var pendingDocument = try responseDocument()
        var pendingPayload = pendingDocument["payload"] as! [String: Any]
        var pendingSnapshot = pendingPayload["snapshot"] as! [String: Any]
        pendingSnapshot["pendingApproval"] = [
            "connectionId": "pending-1",
            "remoteId": "remote-1",
            "remoteName": "Mini",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "requestedAt": 40,
            "expiresAt": 80,
            "requestedCapabilities": ["viewDisplay", "readClipboard"],
            "transport": "relay",
            "authenticationMethod": "localApproval",
            "riskAlerts": [],
        ]
        pendingPayload["snapshot"] = pendingSnapshot
        pendingDocument = try replacingPayload(
            pendingDocument,
            pendingPayload
        )

        let pending = try HostAgentXPCWireSnapshotResponse.decode(
            data(pendingDocument)
        ).snapshot.pendingApproval
        XCTAssertEqual(pending?.connectionID, "pending-1")
        XCTAssertEqual(pending?.remoteID, "remote-1")
        XCTAssertEqual(
            pending?.requestedCapabilities,
            ["viewDisplay", "readClipboard"]
        )
        XCTAssertEqual(pending?.transport, "relay")

        var activeDocument = try responseDocument()
        var activePayload = activeDocument["payload"] as! [String: Any]
        var activeSnapshot = activePayload["snapshot"] as! [String: Any]
        activeSnapshot["activeSession"] = [
            "connectionId": "host-a:session-1",
            "remoteId": "remote-1",
            "remoteName": "Mini",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 40,
            "initialCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "activeCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "inputAvailability": "available",
            "inputUnavailableReason": NSNull(),
        ]
        activePayload["snapshot"] = activeSnapshot
        activeDocument = try replacingPayload(activeDocument, activePayload)

        let active = try HostAgentXPCWireSnapshotResponse.decode(
            data(activeDocument)
        ).snapshot.activeSession
        XCTAssertEqual(active?.connectionID, "host-a:session-1")
        XCTAssertEqual(active?.inputAvailability, .available)
        XCTAssertNil(active?.inputUnavailableReason)

        var invalidActive = activeDocument
        var invalidPayload = invalidActive["payload"] as! [String: Any]
        var invalidSnapshot = invalidPayload["snapshot"] as! [String: Any]
        var invalidSession = invalidSnapshot["activeSession"] as! [String: Any]
        invalidSession["connectionId"] = "host-b:session-1"
        invalidSnapshot["activeSession"] = invalidSession
        invalidPayload["snapshot"] = invalidSnapshot
        invalidActive = try replacingPayload(invalidActive, invalidPayload)
        XCTAssertThrowsError(
            try HostAgentXPCWireSnapshotResponse.decode(data(invalidActive))
        )
    }

    func testContractSourceCannotActivateXPCOrDefineCommandsOrEvents() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCWireSnapshot.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("activate()"))
        XCTAssertFalse(source.contains("exportedObject"))
        XCTAssertFalse(source.contains("HostAgentXPCWireCommand"))
        XCTAssertFalse(source.contains("HostAgentXPCWireEvent"))
    }

    private func makeRequest() throws -> HostAgentXPCWireSnapshotRequest {
        try HostAgentXPCWireSnapshotRequest(
            requestID: requestID,
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            sentAtUnixMilliseconds: 1
        )
    }

    private func makeIdentity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: "host-a",
            agentBootID: bootID
        )
    }

    private func requestDocument() -> [String: Any] {
        [
            "schemaVersion": 1,
            "wireVersion": 1,
            "messageType": "snapshotRequest",
            "requestId": requestID,
            "hostInstanceId": "host-a",
            "agentBootId": bootID,
            "sentAtUnixMilliseconds": 1,
            "payloadLength": 2,
            "payload": [String: Any](),
        ]
    }

    private func responseDocument() throws -> [String: Any] {
        let payload: [String: Any] = [
            "lastEventId": 7,
            "snapshot": [
                "schemaVersion": 6,
                "hostState": "ready",
                "localId": "123456789",
                "registrationStatus": "ready",
                "recoveryEpoch": 0,
                "recoveryStatus": "running",
                "pendingApproval": NSNull(),
                "activeSession": NSNull(),
                "temporaryPasswordPolicy": "redacted",
                "passwordPolicy": [
                    "localPasswordSet": true,
                    "effectivePasswordSet": true,
                    "usingPresetPassword": false,
                    "changeAllowed": true,
                    "strengthPolicyVersion": 1,
                    "minimumCharacters": 6,
                    "maximumCharacters": 128,
                    "maximumUtf8Bytes": 512,
                    "rejectsControlCharacters": true,
                    "rejectsOuterWhitespace": true,
                ],
                "lastError": NSNull(),
                "observedAt": 42,
            ],
        ]
        return [
            "schemaVersion": 1,
            "wireVersion": 1,
            "messageType": "snapshotResponse",
            "requestId": requestID,
            "hostInstanceId": "host-a",
            "agentBootId": bootID,
            "sentAtUnixMilliseconds": 2,
            "payloadLength": try canonicalPayloadLength(payload),
            "payload": payload,
        ]
    }

    private func replacingPayload(
        _ document: [String: Any],
        _ replacement: [String: Any]
    ) throws -> [String: Any] {
        var copy = document
        let payload = (document["payload"] as? [String: Any] ?? [:])
            .merging(replacement) { _, new in new }
        copy["payload"] = payload
        copy["payloadLength"] = try canonicalPayloadLength(payload)
        return copy
    }

    private func canonicalPayloadLength(
        _ payload: [String: Any]
    ) throws -> Int {
        try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ).count
    }

    private func coreSnapshot(
        host: String,
        observedAt: UInt64,
        revealedPassword: String? = nil
    ) throws -> HostCoreSnapshot {
        let presentation: [String: Any] = revealedPassword.map {
            ["policy": "revealed", "value": $0]
        } ?? ["policy": "redacted"]
        return try HostCoreSnapshot(rawJSON: data([
            "schemaVersion": 7,
            "hostInstanceId": host,
            "hostState": "ready",
            "localId": "123456789",
            "sessionAvailability": "available",
            "sessionUnavailableReason": NSNull(),
            "registrationStatus": "ready",
            "recoveryEpoch": 0,
            "recoveryStatus": "running",
            "pendingApproval": NSNull(),
            "activeSession": NSNull(),
            "temporaryPasswordPresentation": presentation,
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
            "observedAt": observedAt,
        ]))
    }

    private func merging(
        _ document: [String: Any],
        _ replacement: [String: Any]
    ) -> [String: Any] {
        document.merging(replacement) { _, new in new }
    }

    private func removing(
        _ document: [String: Any],
        _ key: String
    ) -> [String: Any] {
        var copy = document
        copy.removeValue(forKey: key)
        return copy
    }

    private func data(_ document: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: document)
    }
}
