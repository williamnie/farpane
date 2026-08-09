@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCWireHandshakeTests: XCTestCase {
    func testProductOfferUsesOnlyTheFrozenWireVersionAuthority() throws {
        let request = try HostAgentXPCWireHandshakeRequest.makeProductRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            appBuildID: "202608080001",
            knownHostInstanceID: nil,
            knownAgentBootID: nil,
            sentAtUnixMilliseconds: 1
        )

        XCTAssertEqual(
            request.supportedWireVersions,
            HostAgentXPCWireHandshakeContract.supportedWireVersions
        )
        XCTAssertEqual(request.supportedWireVersions, [2])
        XCTAssertEqual(
            try HostAgentXPCWireHandshakeRequest.decode(request.encoded()),
            request
        )
    }

    func testNegotiatesHighestCommonVersionAndRoundTripsExactDocuments() throws {
        let request = try HostAgentXPCWireHandshakeRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            supportedWireVersions: [1, 2, 3],
            appBuildID: "202608080001",
            knownHostInstanceID: "host-before-reconnect",
            knownAgentBootID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            knownAgentProcessID: 2_345,
            knownAgentProcessStartIdentitySHA256:
                String(repeating: "b", count: 64),
            sentAtUnixMilliseconds: 1_786_153_920_000
        )
        XCTAssertEqual(
            try HostAgentXPCWireHandshakeRequest.decode(request.encoded()),
            request
        )

        let response = try HostAgentXPCWireHandshakeNegotiator.makeResponse(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "202608080002",
                hostInstanceID: "host-after-reconnect",
                agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7"
            ),
            sentAtUnixMilliseconds: 1_786_153_920_010
        )

        XCTAssertEqual(response.compatibility, .compatible)
        XCTAssertEqual(response.selectedWireVersion, 2)
        XCTAssertEqual(response.supportedWireVersions, [2])
        XCTAssertEqual(
            try HostAgentXPCWireHandshakeResponse.decode(response.encoded()),
            response
        )
        XCTAssertEqual(
            HostAgentXPCWireHandshakeNegotiator.evaluate(
                response,
                for: request
            ),
            .compatible(selectedWireVersion: 2)
        )
    }

    func testNoCommonVersionProducesCorrelatedIncompatibleResponse() throws {
        let request = try makeRequest(supportedWireVersions: [1, 3])
        let response = try HostAgentXPCWireHandshakeNegotiator.makeResponse(
            for: request,
            identity: try HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: "host-instance",
                agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7"
            ),
            sentAtUnixMilliseconds: 2
        )

        XCTAssertEqual(response.compatibility, .incompatible)
        XCTAssertNil(response.selectedWireVersion)
        XCTAssertEqual(
            try HostAgentXPCWireHandshakeResponse.decode(response.encoded()),
            response
        )
        XCTAssertEqual(
            HostAgentXPCWireHandshakeNegotiator.evaluate(
                response,
                for: request
            ),
            .incompatible
        )
    }

    func testRequestDecoderRejectsUnknownMalformedAndUnboundedInput() throws {
        let valid = requestDocument()
        let malformedDocuments: [[String: Any]] = [
            merging(valid, ["unknown": true]),
            removing(valid, "requestId"),
            merging(valid, ["schemaVersion": 1]),
            merging(valid, ["messageType": "command"]),
            merging(valid, ["requestId": "NOT-A-CANONICAL-UUID"]),
            merging(valid, ["supportedWireVersions": []]),
            merging(valid, ["supportedWireVersions": [1, 1]]),
            merging(valid, ["supportedWireVersions": [2, 1]]),
            merging(valid, ["supportedWireVersions": [true]]),
            merging(valid, ["supportedWireVersions": [1.5]]),
            merging(valid, ["supportedWireVersions": Array(1...9)]),
            merging(valid, ["appBuildId": "build/invalid"]),
            merging(valid, ["hostInstanceId": ""]),
            merging(valid, ["hostInstanceId": "host-valid"]),
            merging(valid, ["agentBootId": "not-a-uuid"]),
            merging(valid, [
                "agentBootId": "6973cef9-a610-4183-ac81-287fd5f298b7",
            ]),
            merging(valid, ["agentProcessId": 1]),
            merging(valid, [
                "agentProcessStartIdentitySHA256":
                    String(repeating: "A", count: 64),
            ]),
            merging(valid, ["agentProcessId": 2_345]),
            merging(valid, ["sentAtUnixMilliseconds": false]),
            merging(valid, ["sentAtUnixMilliseconds": 0]),
        ]

        for document in malformedDocuments {
            XCTAssertThrowsError(
                try HostAgentXPCWireHandshakeRequest.decode(data(document))
            )
        }
        XCTAssertThrowsError(
            try HostAgentXPCWireHandshakeRequest.decode(Data())
        )
        XCTAssertThrowsError(
            try HostAgentXPCWireHandshakeRequest.decode(
                Data(
                    repeating: 0x20,
                    count: HostAgentXPCWireHandshakeContract
                        .maximumDocumentBytes + 1
                )
            )
        )
    }

    func testDecoderReportsOnlyStableDocumentFailureClasses() throws {
        XCTAssertThrowsError(
            try HostAgentXPCWireHandshakeRequest.decode(
                data(merging(requestDocument(), ["schemaVersion": 1]))
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireHandshakeDocumentError,
                .unsupportedSchema(1)
            )
        }
        XCTAssertThrowsError(
            try HostAgentXPCWireHandshakeRequest.decode(Data())
        ) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireHandshakeDocumentError,
                .invalidDocument
            )
        }
        XCTAssertThrowsError(
            try HostAgentXPCWireHandshakeRequest.decode(Data(
                repeating: 0x20,
                count: HostAgentXPCWireHandshakeContract.maximumDocumentBytes + 1
            ))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireHandshakeDocumentError,
                .documentTooLarge
            )
        }
    }

    func testResponseDecoderRejectsContradictoryCompatibilityShape() throws {
        let valid = responseDocument()
        let malformedDocuments: [[String: Any]] = [
            merging(valid, ["unknown": true]),
            merging(valid, ["messageType": "handshakeRequest"]),
            merging(valid, ["compatibility": "future"]),
            merging(valid, ["selectedWireVersion": NSNull()]),
            merging(valid, [
                "compatibility": "incompatible",
                "selectedWireVersion": 1,
            ]),
            merging(valid, ["supportedWireVersions": [1]]),
            merging(valid, ["agentBuildId": "agent build"]),
            merging(valid, ["hostInstanceId": NSNull()]),
            merging(valid, ["agentBootId": "UPPERCASE-NOT-UUID"]),
            merging(valid, ["agentProcessId": 1]),
            merging(valid, [
                "agentProcessStartIdentitySHA256":
                    String(repeating: "A", count: 64),
            ]),
        ]

        for document in malformedDocuments {
            XCTAssertThrowsError(
                try HostAgentXPCWireHandshakeResponse.decode(data(document))
            )
        }
    }

    func testEvaluationRejectsUncorrelatedOrUnofferedCompatibleResponse() throws {
        let request = try makeRequest(supportedWireVersions: [2])
        let wrongRequest = try makeRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            supportedWireVersions: [2]
        )
        let uncorrelated = try HostAgentXPCWireHandshakeNegotiator.makeResponse(
            for: wrongRequest,
            identity: try HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: "host-instance",
                agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7"
            ),
            sentAtUnixMilliseconds: 2
        )
        XCTAssertEqual(
            HostAgentXPCWireHandshakeNegotiator.evaluate(
                uncorrelated,
                for: request
            ),
            .invalidResponse
        )

        let legacyRequest = try makeRequest(supportedWireVersions: [1])
        let unoffered = try HostAgentXPCWireHandshakeResponse.decode(data(
            responseDocument(selectedWireVersion: 2)
        ))
        XCTAssertEqual(
            HostAgentXPCWireHandshakeNegotiator.evaluate(
                unoffered,
                for: legacyRequest
            ),
            .invalidResponse
        )
    }

    func testContractSourceCannotActivateXPCOrDefineCommands() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCWireHandshake.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("activate()"))
        XCTAssertFalse(source.contains("exportedObject"))
        XCTAssertFalse(source.contains("command"))
        XCTAssertFalse(source.contains("snapshot"))
    }

    private func makeRequest(
        requestID: String = "287fd5f2-98b7-4183-ac81-6973cef9a610",
        supportedWireVersions: [UInt64]
    ) throws -> HostAgentXPCWireHandshakeRequest {
        try HostAgentXPCWireHandshakeRequest(
            requestID: requestID,
            supportedWireVersions: supportedWireVersions,
            appBuildID: "app-build",
            knownHostInstanceID: nil,
            knownAgentBootID: nil,
            sentAtUnixMilliseconds: 1
        )
    }

    private func requestDocument() -> [String: Any] {
        [
            "schemaVersion": 2,
            "messageType": "handshakeRequest",
            "requestId": "287fd5f2-98b7-4183-ac81-6973cef9a610",
            "supportedWireVersions": [2],
            "appBuildId": "app-build",
            "hostInstanceId": NSNull(),
            "agentBootId": NSNull(),
            "agentProcessId": NSNull(),
            "agentProcessStartIdentitySHA256": NSNull(),
            "sentAtUnixMilliseconds": 1,
        ]
    }

    private func responseDocument(
        selectedWireVersion: Any = 2
    ) -> [String: Any] {
        [
            "schemaVersion": 2,
            "messageType": "handshakeResponse",
            "requestId": "287fd5f2-98b7-4183-ac81-6973cef9a610",
            "supportedWireVersions": [2],
            "selectedWireVersion": selectedWireVersion,
            "compatibility": "compatible",
            "agentBuildId": "agent-build",
            "hostInstanceId": "host-instance",
            "agentBootId": "6973cef9-a610-4183-ac81-287fd5f298b7",
            "agentProcessId": 4_321,
            "agentProcessStartIdentitySHA256":
                String(repeating: "a", count: 64),
            "sentAtUnixMilliseconds": 2,
        ]
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
