@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCWireCommandTests: XCTestCase {
    private let requestID = "287fd5f2-98b7-4183-ac81-6973cef9a610"
    private let secondRequestID = "151db9a9-7dd3-4fea-93af-1b6c10840676"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
    private let hostID = "host-a"
    private let commandID = "command-1"

    func testEightApprovalAndSessionCommandsRoundTripExactly() throws {
        let names: [HostAgentXPCWireCommandName] = [
            .approveIncoming,
            .rejectIncoming,
            .disableInputForActiveSession,
            .disableClipboardReadForActiveSession,
            .disableClipboardWriteForActiveSession,
            .disableClipboardForActiveSession,
            .disableAudioForActiveSession,
            .disconnectSession,
        ]

        for name in names {
            let request = try makeRequest(name: name)
            XCTAssertEqual(request.name, name)
            XCTAssertEqual(request.commandID, commandID)
            XCTAssertEqual(request.connectionID, "host-a:connection-1")
            XCTAssertEqual(request.schemaVersion, 2)
            XCTAssertEqual(
                try HostAgentXPCWireCommandRequest.decode(request.encoded()),
                request
            )
        }
    }

    func testSameCommandIDCanRetryWithFreshRequestCorrelation() throws {
        let first = try makeRequest()
        let retry = try makeRequest(requestID: secondRequestID)

        XCTAssertNotEqual(first.requestID, retry.requestID)
        XCTAssertEqual(first.commandID, retry.commandID)
        XCTAssertEqual(first.name, retry.name)
        XCTAssertEqual(first.connectionID, retry.connectionID)
        XCTAssertEqual(first.hostInstanceID, retry.hostInstanceID)
        XCTAssertEqual(first.agentBootID, retry.agentBootID)
    }

    func testAcceptedResponseRoundTripsAndRequiresFullCorrelation() throws {
        let request = try makeRequest()
        let response = try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: makeIdentity(),
            sentAtUnixMilliseconds: 2
        )

        XCTAssertEqual(response.acceptance, .queued)
        XCTAssertEqual(
            try HostAgentXPCWireCommandAcceptedResponse.decode(
                response.encoded()
            ),
            response
        )
        XCTAssertEqual(response.evaluate(for: request), .correlated)
        XCTAssertEqual(
            response.evaluate(for: try makeRequest(
                requestID: secondRequestID
            )),
            .invalidResponse
        )
        XCTAssertEqual(
            response.evaluate(for: try makeRequest(
                commandID: "command-2"
            )),
            .invalidResponse
        )
    }

    func testAcceptedFactoryRejectsForeignIdentity() throws {
        let request = try makeRequest()
        XCTAssertThrowsError(
            try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
                for: request,
                identity: try HostAgentXPCWireAgentIdentity.test(
                    agentBuildID: "202608090001",
                    hostInstanceID: "host-b",
                    agentBootID: bootID
                ),
                sentAtUnixMilliseconds: 2
            )
        )
        XCTAssertThrowsError(
            try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
                for: request,
                identity: try HostAgentXPCWireAgentIdentity.test(
                    agentBuildID: "202608090001",
                    hostInstanceID: hostID,
                    agentBootID:
                        "5dd81b11-0f26-4d13-bc33-72fd0eff6c28"
                ),
                sentAtUnixMilliseconds: 2
            )
        )
    }

    func testRequestDecoderRejectsUnknownMalformedAndUnboundedDocuments()
        throws
    {
        let valid = try requestDocument()
        let payload = valid["payload"] as! [String: Any]
        let malformed: [[String: Any]] = [
            merging(valid, ["unknown": true]),
            removing(valid, "commandId"),
            merging(valid, ["schemaVersion": 1]),
            merging(valid, ["schemaVersion": 3]),
            merging(valid, ["wireVersion": 1]),
            merging(valid, ["wireVersion": true]),
            merging(valid, ["messageType": "snapshotRequest"]),
            merging(valid, ["requestId": "NOT-A-CANONICAL-UUID"]),
            merging(valid, ["commandId": "command/invalid"]),
            merging(valid, ["hostInstanceId": "host/invalid"]),
            merging(valid, ["agentBootId": "not-a-uuid"]),
            merging(valid, ["sentAtUnixMilliseconds": false]),
            merging(valid, ["sentAtUnixMilliseconds": 0]),
            merging(valid, ["payloadLength": 1]),
            try replacingPayload(valid, merging(payload, [
                "unknown": true,
            ])),
            try replacingPayload(valid, merging(payload, [
                "name": "futureCommand",
            ])),
            try replacingPayload(valid, merging(payload, [
                "connectionId": "host-b:connection-1",
            ])),
            try replacingPayload(valid, merging(payload, [
                "connectionId": "host-a:",
            ])),
            try replacingPayload(valid, merging(payload, [
                "connectionId": "host-a:connection\n1",
            ])),
        ]

        for document in malformed {
            XCTAssertThrowsError(
                try HostAgentXPCWireCommandRequest.decode(data(document))
            )
        }
        XCTAssertThrowsError(
            try HostAgentXPCWireCommandRequest.decode(Data())
        )
        XCTAssertThrowsError(
            try HostAgentXPCWireCommandRequest.decode(Data(
                repeating: 0x20,
                count: HostAgentXPCWireCommandContract.maximumDocumentBytes + 1
            ))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireCommandDocumentError,
                .documentTooLarge
            )
        }
    }

    func testAcceptedDecoderRejectsNonQueuedOrMalformedShapes() throws {
        let valid = try acceptedDocument()
        let payload = valid["payload"] as! [String: Any]
        let malformed: [[String: Any]] = [
            merging(valid, ["unknown": true]),
            removing(valid, "requestId"),
            merging(valid, ["schemaVersion": 1]),
            merging(valid, ["schemaVersion": 3]),
            merging(valid, ["wireVersion": 1]),
            merging(valid, ["messageType": "commandRequest"]),
            merging(valid, ["requestId": "not-a-uuid"]),
            merging(valid, ["commandId": "command/invalid"]),
            merging(valid, ["hostInstanceId": "host/invalid"]),
            merging(valid, ["agentBootId": "not-a-uuid"]),
            merging(valid, ["sentAtUnixMilliseconds": false]),
            merging(valid, ["payloadLength": 1]),
            try replacingPayload(valid, ["acceptance": "completed"]),
            try replacingPayload(valid, ["acceptance": true]),
            try replacingPayload(valid, merging(payload, ["unknown": true])),
        ]

        for document in malformed {
            XCTAssertThrowsError(
                try HostAgentXPCWireCommandAcceptedResponse.decode(
                    data(document)
                )
            )
        }
    }

    func testContractIsDataOnlyAndContainsNoSecretBearingCommand() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCWireCommand.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("performCommand"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.lowercased().contains("password"))
        XCTAssertFalse(source.lowercased().contains("secret"))
        XCTAssertFalse(source.lowercased().contains("credential"))
    }

    private func makeRequest(
        requestID: String? = nil,
        commandID: String? = nil,
        name: HostAgentXPCWireCommandName = .approveIncoming
    ) throws -> HostAgentXPCWireCommandRequest {
        try HostAgentXPCWireCommandRequest(
            requestID: requestID ?? self.requestID,
            commandID: commandID ?? self.commandID,
            wireVersion: 2,
            hostInstanceID: hostID,
            agentBootID: bootID,
            name: name,
            connectionID: "host-a:connection-1",
            sentAtUnixMilliseconds: 1
        )
    }

    private func makeIdentity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "202608090001",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func requestDocument() throws -> [String: Any] {
        try object(try makeRequest().encoded())
    }

    private func acceptedDocument() throws -> [String: Any] {
        try object(try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: makeRequest(),
            identity: makeIdentity(),
            sentAtUnixMilliseconds: 2
        ).encoded())
    }

    private func replacingPayload(
        _ document: [String: Any],
        _ replacement: [String: Any]
    ) throws -> [String: Any] {
        var copy = document
        copy["payload"] = replacement
        copy["payloadLength"] = try JSONSerialization.data(
            withJSONObject: replacement,
            options: [.sortedKeys]
        ).count
        return copy
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func merging(
        _ base: [String: Any],
        _ additions: [String: Any]
    ) -> [String: Any] {
        var copy = base
        for (key, value) in additions { copy[key] = value }
        return copy
    }

    private func removing(
        _ base: [String: Any],
        _ key: String
    ) -> [String: Any] {
        var copy = base
        copy.removeValue(forKey: key)
        return copy
    }
}
