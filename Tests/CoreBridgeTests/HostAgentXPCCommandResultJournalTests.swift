@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCCommandResultJournalTests: XCTestCase {
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
    private let hostID = "host-a"
    private let sentAt: UInt64 = 1_700_000_000_000

    func testRawCommandResultIsRejectedButTypedRecordReplays() throws {
        let state = try HostAgentEventState(
            capacity: 4,
            maximumEventBytes: 4_096
        )
        let raw = try coreCommandResultEvent(eventID: 71)
        let result = try commandResult()

        XCTAssertEqual(
            state.ingest(raw),
            .rejected(.typedCommandResultRequired)
        )
        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: sentAt
            ),
            .accepted(sequence: 1)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.latestSequence, 1)
        XCTAssertEqual(snapshot.hostInstanceID, hostID)
        XCTAssertEqual(snapshot.records.count, 1)
        guard case .commandResult(
            let recorded,
            let recordedSentAt
        ) = snapshot.records[0].payload else {
            return XCTFail("expected typed command result record")
        }
        XCTAssertEqual(recorded, result)
        XCTAssertEqual(recordedSentAt, sentAt)

        let request = try eventRequest()
        let response = try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: identity(),
            replay: state.replay(afterSequence: 0, limit: 4),
            sentAtUnixMilliseconds: sentAt + 1
        )
        XCTAssertEqual(response.outcome, .batch)
        XCTAssertEqual(response.resumeAfterEventID, 1)
        XCTAssertEqual(
            response.events.map(\.payload),
            [.commandResult(result)]
        )
    }

    func testTypedResultDedupesWhileRetainedAndCanReappendAfterEviction()
        throws
    {
        let state = try HostAgentEventState(
            capacity: 2,
            maximumEventBytes: 4_096
        )
        let result = try commandResult()
        let conflicting = try commandResult(status: .error, detail: "failed")

        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: sentAt
            ),
            .accepted(sequence: 1)
        )
        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: sentAt + 99
            ),
            .unchanged(sequence: 1)
        )
        XCTAssertEqual(
            state.ingestCommandResult(
                conflicting,
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: sentAt
            ),
            .rejected(.conflictingCommandResult)
        )

        XCTAssertEqual(
            state.ingest(try coreEvent(eventID: 1)),
            .accepted(sequence: 2)
        )
        XCTAssertEqual(
            state.ingest(try coreEvent(eventID: 2)),
            .accepted(sequence: 3)
        )
        XCTAssertEqual(state.snapshot().firstAvailableSequence, 2)
        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: sentAt + 100
            ),
            .accepted(sequence: 4)
        )
        XCTAssertEqual(state.snapshot().firstAvailableSequence, 3)
        XCTAssertEqual(state.snapshot().evictedEventCount, 2)
    }

    func testTypedResultRejectsInvalidOrForeignJournalIdentity() throws {
        let state = try HostAgentEventState()
        let result = try commandResult()

        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: "",
                sentAtUnixMilliseconds: sentAt
            ),
            .rejected(.invalidHostInstance)
        )
        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: 0
            ),
            .rejected(.invalidTimestamp)
        )
        XCTAssertEqual(
            state.ingest(try coreEvent(eventID: 1)),
            .accepted(sequence: 1)
        )
        XCTAssertEqual(
            state.ingestCommandResult(
                result,
                hostInstanceID: "host-b",
                sentAtUnixMilliseconds: sentAt
            ),
            .rejected(.foreignHostInstance)
        )
        XCTAssertEqual(state.snapshot().latestSequence, 1)
    }

    func testCommandServiceConsumesStrictCoreResultIntoTypedJournal()
        throws
    {
        let state = try HostAgentEventState(
            capacity: 2,
            maximumEventBytes: 4_096
        )
        let authority = try HostAgentXPCCommandAdmissionAuthority(
            identity: identity()
        )
        let service = HostAgentXPCCommandService(
            identity: try identity(),
            authority: authority,
            prepareExecution: { _ in
                HostAgentXPCCommandQueueTicket {}
            },
            publishResult: { result in
                switch state.ingestCommandResult(
                    result,
                    hostInstanceID: self.hostID,
                    sentAtUnixMilliseconds: self.sentAt
                ) {
                case .accepted, .unchanged:
                    return true
                case .rejected:
                    return false
                }
            },
            nowUnixMilliseconds: { self.sentAt }
        )
        let request = try commandRequest()
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))
        XCTAssertTrue(prepared.performAfterReply())
        let raw = try coreCommandResultEvent(eventID: 91)

        XCTAssertEqual(
            service.consumeCoreResultEvent(raw),
            .delivered(.published)
        )
        XCTAssertEqual(state.snapshot().latestSequence, 1)
        XCTAssertEqual(authority.snapshot().completedCount, 1)
        XCTAssertEqual(
            service.consumeCoreResultEvent(raw),
            .delivered(.unchanged)
        )
        XCTAssertEqual(state.snapshot().latestSequence, 1)

        let retry = try commandRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676"
        )
        let replay = try XCTUnwrap(service.prepareResponse(
            for: try retry.encoded()
        ))
        XCTAssertTrue(replay.performAfterReply())
        XCTAssertEqual(state.snapshot().latestSequence, 1)

        XCTAssertEqual(
            state.ingest(try coreEvent(eventID: 1)),
            .accepted(sequence: 2)
        )
        XCTAssertEqual(
            state.ingest(try coreEvent(eventID: 2)),
            .accepted(sequence: 3)
        )
        XCTAssertEqual(state.snapshot().firstAvailableSequence, 2)

        let postEvictionRetry = try commandRequest(
            requestID: "948197e3-27ad-47fb-a3c9-617d6eca2596"
        )
        let republished = try XCTUnwrap(service.prepareResponse(
            for: try postEvictionRetry.encoded()
        ))
        XCTAssertTrue(republished.performAfterReply())
        let republishedSnapshot = state.snapshot()
        XCTAssertEqual(republishedSnapshot.latestSequence, 4)
        XCTAssertEqual(authority.snapshot().completedCount, 1)
        guard case .commandResult(let replayedResult, _) =
            republishedSnapshot.records.last?.payload
        else { return XCTFail("expected republished typed result") }
        XCTAssertEqual(replayedResult, try commandResult())
    }

    func testCoreResultConsumerRejectsMalformedForeignAndUnknownResults()
        throws
    {
        let state = try HostAgentEventState()
        let authority = try HostAgentXPCCommandAdmissionAuthority(
            identity: identity()
        )
        let service = HostAgentXPCCommandService(
            identity: try identity(),
            authority: authority,
            prepareExecution: { _ in HostAgentXPCCommandQueueTicket {} },
            publishResult: { result in
                if case .accepted = state.ingestCommandResult(
                    result,
                    hostInstanceID: self.hostID,
                    sentAtUnixMilliseconds: self.sentAt
                ) { return true }
                return false
            },
            nowUnixMilliseconds: { self.sentAt }
        )
        let queued = try commandRequest()
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try queued.encoded()
        ))
        XCTAssertTrue(prepared.performAfterReply())

        XCTAssertEqual(
            service.consumeCoreResultEvent(try coreEvent(eventID: 1)),
            .notCommandResult
        )
        XCTAssertEqual(
            service.consumeCoreResultEvent(try coreCommandResultEvent(
                eventID: 2,
                additionalTopLevel: ["secret": "must-not-cross"]
            )),
            .malformed
        )
        XCTAssertEqual(
            service.consumeCoreResultEvent(try coreCommandResultEvent(
                eventID: 3,
                hostInstanceID: "host-b"
            )),
            .foreignIdentity
        )
        XCTAssertEqual(
            service.consumeCoreResultEvent(try coreCommandResultEvent(
                eventID: 4,
                commandID: "unknown-command"
            )),
            .delivered(.unknownCommand)
        )
        XCTAssertEqual(state.snapshot().latestSequence, 0)
        XCTAssertEqual(authority.snapshot().queuedCount, 1)
    }

    private func identity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "202608090001",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func commandRequest(
        requestID: String = "287fd5f2-98b7-4183-ac81-6973cef9a610"
    ) throws -> HostAgentXPCWireCommandRequest {
        try HostAgentXPCWireCommandRequest(
            requestID: requestID,
            commandID: "command-1",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            name: .disconnectSession,
            connectionID: "host-a:connection-1",
            sentAtUnixMilliseconds: sentAt
        )
    }

    private func eventRequest() throws -> HostAgentXPCWireEventCursorRequest {
        try HostAgentXPCWireEventCursorRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: 0,
            maximumEventCount: 4,
            sentAtUnixMilliseconds: sentAt
        )
    }

    private func commandResult(
        commandID: String = "command-1",
        status: HostAgentXPCWireCommandResultStatus = .ok,
        detail: String = "completed"
    ) throws -> HostAgentXPCWireCommandResult {
        try HostAgentXPCWireCommandResult(
            commandID: commandID,
            status: status,
            detail: detail
        )
    }

    private func coreEvent(eventID: UInt64) throws -> HostCoreEvent {
        try coreEvent(
            eventID: eventID,
            eventType: "snapshotChanged",
            payload: [:]
        )
    }

    private func coreCommandResultEvent(
        eventID: UInt64,
        commandID: String = "command-1",
        hostInstanceID: String? = nil,
        additionalTopLevel: [String: Any] = [:]
    ) throws -> HostCoreEvent {
        try coreEvent(
            eventID: eventID,
            eventType: "commandResult",
            payload: [
                "commandId": commandID,
                "status": "ok",
                "detail": "completed",
            ],
            hostInstanceID: hostInstanceID,
            additionalTopLevel: additionalTopLevel
        )
    }

    private func coreEvent(
        eventID: UInt64,
        eventType: String,
        payload: [String: Any],
        hostInstanceID: String? = nil,
        additionalTopLevel: [String: Any] = [:]
    ) throws -> HostCoreEvent {
        var envelope: [String: Any] = [
            "schemaVersion": 1,
            "eventId": eventID,
            "eventType": eventType,
            "hostInstanceId": hostInstanceID ?? hostID,
            "sentAt": sentAt,
            "payload": payload,
        ]
        for (key, value) in additionalTopLevel { envelope[key] = value }
        return try XCTUnwrap(HostCoreEvent(rawJSON:
            JSONSerialization.data(withJSONObject: envelope)
        ))
    }
}
