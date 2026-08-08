@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCWireEventTests: XCTestCase {
    private let requestID = "287fd5f2-98b7-4183-ac81-6973cef9a610"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
    private let hostID = "host-a"

    func testCursorRequestRoundTripsWithExactBoundedEnvelope() throws {
        let request = try cursorRequest(afterEventID: 7, maximumEventCount: 64)
        let data = try request.encoded()

        XCTAssertEqual(try HostAgentXPCWireEventCursorRequest.decode(data), request)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(document.keys), Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "hostInstanceId", "agentBootId", "sentAtUnixMilliseconds",
            "payloadLength", "payload",
        ]))
        XCTAssertEqual(document["messageType"] as? String, "eventCursorRequest")
        let payload = try XCTUnwrap(document["payload"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), Set([
            "afterEventId", "maximumEventCount",
        ]))
        XCTAssertEqual((payload["afterEventId"] as? NSNumber)?.uint64Value, 7)
        XCTAssertEqual(
            (payload["maximumEventCount"] as? NSNumber)?.uint64Value,
            64
        )
        XCTAssertLessThanOrEqual(
            data.count,
            HostAgentXPCWireEventContract.maximumDocumentBytes
        )
    }

    func testCursorRequestRejectsUnknownBooleanFractionLimitAndOversize() throws {
        let valid = try requestDocument(afterEventID: 0, maximumEventCount: 1)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["unexpected"] = true },
            {
                var payload = $0["payload"] as! [String: Any]
                payload["afterEventId"] = true
                $0["payload"] = payload
            },
            {
                var payload = $0["payload"] as! [String: Any]
                payload["afterEventId"] = 1.5
                $0["payload"] = payload
            },
            {
                var payload = $0["payload"] as! [String: Any]
                payload["maximumEventCount"] = 0
                $0["payload"] = payload
            },
            {
                var payload = $0["payload"] as! [String: Any]
                payload["maximumEventCount"] = 65
                $0["payload"] = payload
            },
            { $0["payloadLength"] = 999 },
        ]
        for mutate in mutations {
            var document = valid
            mutate(&document)
            XCTAssertThrowsError(try HostAgentXPCWireEventCursorRequest.decode(
                JSONSerialization.data(withJSONObject: document)
            ))
        }

        let encoded = try cursorRequest().encoded()
        let oversized = encoded + Data(
            repeating: 0x20,
            count: HostAgentXPCWireEventContract.maximumDocumentBytes
        )
        XCTAssertThrowsError(try HostAgentXPCWireEventCursorRequest.decode(
            oversized
        )) { error in
            XCTAssertEqual(
                error as? HostAgentXPCWireEventDocumentError,
                .documentTooLarge
            )
        }
    }

    func testBatchProjectsStateAndCommandButSuppressesAgentDiagnostics() throws {
        let state = try HostAgentEventState(capacity: 8, maximumEventBytes: 4_096)
        _ = state.ingest(try event(
            id: 10,
            type: "sessionStarted",
            payload: ["remoteName": "private-peer-name"]
        ))
        _ = state.ingest(try event(
            id: 11,
            type: "mediaDiagnostic",
            payload: ["credential": "must-not-cross-xpc"]
        ))
        _ = state.ingest(try event(
            id: 12,
            type: "commandResult",
            payload: [
                "commandId": "command-1",
                "status": "ok",
                "detail": "session-disconnect-queued",
            ]
        ))
        let request = try cursorRequest(maximumEventCount: 8)
        let response = try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: state.replay(afterSequence: 0, limit: 8),
            sentAtUnixMilliseconds: 20
        )

        XCTAssertEqual(response.outcome, .batch)
        XCTAssertEqual(response.latestEventID, 3)
        XCTAssertEqual(response.resumeAfterEventID, 3)
        XCTAssertEqual(response.hasMore, false)
        XCTAssertEqual(response.events.map(\.eventID), [1, 3])
        XCTAssertEqual(response.events[0].payload, .snapshotChanged)
        XCTAssertEqual(
            response.events[1].payload,
            .commandResult(try HostAgentXPCWireCommandResult(
                commandID: "command-1",
                status: .ok,
                detail: "session-disconnect-queued"
            ))
        )

        let encoded = try response.encoded()
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("private-peer-name"))
        XCTAssertFalse(encodedText.contains("must-not-cross-xpc"))
        XCTAssertFalse(encodedText.contains("credential"))
        XCTAssertEqual(
            try HostAgentXPCWireEventCursorResponse.decode(encoded),
            response
        )
        XCTAssertEqual(response.evaluate(for: request), .correlated)
    }

    func testBatchPreservesReplayPaginationCursorAndHasMore() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 4_096)
        for eventID in 1...3 {
            _ = state.ingest(try event(
                id: UInt64(eventID),
                type: "snapshotChanged",
                payload: [:]
            ))
        }
        let request = try cursorRequest(maximumEventCount: 2)
        let response = try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: state.replay(afterSequence: 0, limit: 2),
            sentAtUnixMilliseconds: 20
        )

        XCTAssertEqual(response.outcome, .batch)
        XCTAssertEqual(response.events.map(\.eventID), [2])
        XCTAssertEqual(response.events.first?.payload, .snapshotChanged)
        XCTAssertEqual(response.latestEventID, 3)
        XCTAssertEqual(response.resumeAfterEventID, 2)
        XCTAssertEqual(response.hasMore, true)
    }

    func testReplayTerminalOutcomesMapWithoutInventingEvents() throws {
        let empty = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)
        let upToDateRequest = try cursorRequest()
        let upToDate = try HostAgentXPCWireEventCursorResponse.make(
            for: upToDateRequest,
            identity: try identity(),
            replay: empty.replay(afterSequence: 0, limit: 2),
            sentAtUnixMilliseconds: 20
        )
        XCTAssertEqual(upToDate.outcome, .upToDate)
        XCTAssertEqual(upToDate.latestEventID, 0)
        XCTAssertNil(upToDate.firstAvailableEventID)
        XCTAssertNil(upToDate.resumeAfterEventID)
        XCTAssertEqual(upToDate.events, [])

        let state = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)
        for eventID in 1...3 {
            _ = state.ingest(try event(
                id: UInt64(eventID),
                type: "snapshotChanged",
                payload: [:]
            ))
        }
        let gap = try HostAgentXPCWireEventCursorResponse.make(
            for: try cursorRequest(),
            identity: try identity(),
            replay: state.replay(afterSequence: 0, limit: 2),
            sentAtUnixMilliseconds: 20
        )
        XCTAssertEqual(gap.outcome, .gap)
        XCTAssertEqual(gap.firstAvailableEventID, 2)
        XCTAssertEqual(gap.latestEventID, 3)
        XCTAssertEqual(gap.events, [])

        let futureRequest = try cursorRequest(afterEventID: 4)
        let invalid = try HostAgentXPCWireEventCursorResponse.make(
            for: futureRequest,
            identity: try identity(),
            replay: state.replay(afterSequence: 4, limit: 2),
            sentAtUnixMilliseconds: 20
        )
        XCTAssertEqual(invalid.outcome, .invalidCursor)
        XCTAssertEqual(invalid.latestEventID, 3)
        XCTAssertEqual(invalid.events, [])
    }

    func testUnknownOrMalformedPublicEventRequiresSnapshotWithoutRawLeak() throws {
        for rawEvent in [
            try event(
                id: 1,
                type: "futureSensitiveEvent",
                payload: ["password": "never-cross"]
            ),
            try event(
                id: 1,
                type: "commandResult",
                payload: [
                    "commandId": "command-1",
                    "status": "ok",
                    "detail": "accepted",
                    "password": "never-cross",
                ]
            ),
            try event(
                id: 1,
                type: "snapshotChanged",
                payload: [:],
                additionalTopLevel: ["secret": "never-cross"]
            ),
        ] {
            let state = try HostAgentEventState(
                capacity: 2,
                maximumEventBytes: 4_096
            )
            _ = state.ingest(rawEvent)
            let request = try cursorRequest(maximumEventCount: 2)
            let response = try HostAgentXPCWireEventCursorResponse.make(
                for: request,
                identity: try identity(),
                replay: state.replay(afterSequence: 0, limit: 2),
                sentAtUnixMilliseconds: 20
            )

            XCTAssertEqual(response.outcome, .resnapshotRequired)
            XCTAssertEqual(response.latestEventID, 1)
            XCTAssertNil(response.resumeAfterEventID)
            XCTAssertEqual(response.events, [])
            let text = try XCTUnwrap(String(
                data: response.encoded(),
                encoding: .utf8
            ))
            XCTAssertFalse(text.contains("never-cross"))
            XCTAssertFalse(text.contains("password"))
            XCTAssertFalse(text.contains("secret"))
        }
    }

    func testForeignJournalHostRequiresSnapshotInsteadOfRebindingWireIdentity()
        throws
    {
        let state = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)
        _ = state.ingest(try event(
            id: 1,
            type: "snapshotChanged",
            payload: [:],
            hostInstanceID: "host-foreign"
        ))
        let request = try cursorRequest(maximumEventCount: 2)
        let response = try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: state.replay(afterSequence: 0, limit: 2),
            sentAtUnixMilliseconds: 20
        )

        XCTAssertEqual(response.outcome, .resnapshotRequired)
        XCTAssertEqual(response.hostInstanceID, hostID)
        XCTAssertEqual(response.events, [])
    }

    func testResponseDecodeRejectsContradictoryShapeAndCorrelation() throws {
        let request = try cursorRequest()
        let state = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)
        let response = try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: state.replay(afterSequence: 0, limit: 2),
            sentAtUnixMilliseconds: 20
        )
        let valid = try XCTUnwrap(
            JSONSerialization.jsonObject(with: response.encoded())
                as? [String: Any]
        )
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["unexpected"] = true },
            { $0["payloadLength"] = 999 },
            {
                var payload = $0["payload"] as! [String: Any]
                payload["events"] = [[
                    "eventId": 1,
                    "eventType": "snapshotChanged",
                    "sentAtUnixMilliseconds": 10,
                    "payloadLength": 2,
                    "payload": [:],
                ]]
                $0["payload"] = payload
            },
            {
                var payload = $0["payload"] as! [String: Any]
                payload["hasMore"] = true
                $0["payload"] = payload
            },
        ]
        for mutate in mutations {
            var document = valid
            mutate(&document)
            XCTAssertThrowsError(try HostAgentXPCWireEventCursorResponse.decode(
                JSONSerialization.data(withJSONObject: document)
            ))
        }

        let otherRequest = try HostAgentXPCWireEventCursorRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: 0,
            maximumEventCount: 1,
            sentAtUnixMilliseconds: 10
        )
        XCTAssertEqual(response.evaluate(for: otherRequest), .invalidResponse)
    }

    func testContractSourceOwnsNoXPCConnectionOrExternalState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCWireEvent.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("NSURL"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
        XCTAssertFalse(source.contains("HostAgentXPCWireCommandRequest"))
        XCTAssertFalse(source.contains("CommandService"))
    }

    private func cursorRequest(
        afterEventID: UInt64 = 0,
        maximumEventCount: Int = 2
    ) throws -> HostAgentXPCWireEventCursorRequest {
        try HostAgentXPCWireEventCursorRequest(
            requestID: requestID,
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: afterEventID,
            maximumEventCount: maximumEventCount,
            sentAtUnixMilliseconds: 10
        )
    }

    private func identity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func requestDocument(
        afterEventID: UInt64,
        maximumEventCount: Int
    ) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(
            with: cursorRequest(
                afterEventID: afterEventID,
                maximumEventCount: maximumEventCount
            ).encoded()
        ) as? [String: Any])
    }

    private func event(
        id: UInt64,
        type: String,
        payload: [String: Any],
        additionalTopLevel: [String: Any] = [:],
        hostInstanceID: String? = nil
    ) throws -> HostCoreEvent {
        var envelope: [String: Any] = [
            "schemaVersion": 1,
            "eventId": id,
            "eventType": type,
            "hostInstanceId": hostInstanceID ?? hostID,
            "sentAt": 1_700_000_000_000 as UInt64,
            "payload": payload,
        ]
        for (key, value) in additionalTopLevel { envelope[key] = value }
        return try XCTUnwrap(HostCoreEvent(rawJSON:
            JSONSerialization.data(withJSONObject: envelope)
        ))
    }
}
