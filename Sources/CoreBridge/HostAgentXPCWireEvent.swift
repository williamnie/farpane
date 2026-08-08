import CoreFoundation
import Foundation

package enum HostAgentXPCWireEventDocumentError: Error, Equatable {
    case invalidDocument
    case documentTooLarge
    case unsupportedSchema(UInt64)
}

package enum HostAgentXPCWireEventEvaluation: Equatable, Sendable {
    case correlated
    case invalidResponse
}

package enum HostAgentXPCWireEventOutcome: String, Equatable, Sendable {
    case upToDate
    case batch
    case gap
    case invalidCursor
    case resnapshotRequired
}

package enum HostAgentXPCWireCommandResultStatus:
    String,
    Equatable,
    Sendable
{
    case ok
    case rejected
    case error
    case unknownCommand
}

package struct HostAgentXPCWireCommandResult: Equatable, Sendable {
    package let commandID: String
    package let status: HostAgentXPCWireCommandResultStatus
    package let detail: String

    package init(
        commandID: String,
        status: HostAgentXPCWireCommandResultStatus,
        detail: String
    ) throws {
        guard HostAgentXPCWireEventContract.validToken(commandID),
              HostAgentXPCWireEventContract.validToken(detail)
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        self.commandID = commandID
        self.status = status
        self.detail = detail
    }

    fileprivate var document: [String: Any] {
        [
            "commandId": commandID,
            "status": status.rawValue,
            "detail": detail,
        ]
    }

    fileprivate init(document: [String: Any]) throws {
        guard Set(document.keys) == Set(["commandId", "status", "detail"]),
              let commandID = document["commandId"] as? String,
              let rawStatus = document["status"] as? String,
              let status = HostAgentXPCWireCommandResultStatus(
                rawValue: rawStatus
              ),
              let detail = document["detail"] as? String
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        try self.init(commandID: commandID, status: status, detail: detail)
    }
}

package enum HostAgentXPCWireEventPayload: Equatable, Sendable {
    case snapshotChanged
    case commandResult(HostAgentXPCWireCommandResult)
}

package struct HostAgentXPCWireEvent: Equatable, Sendable {
    package let eventID: UInt64
    package let sentAtUnixMilliseconds: UInt64
    package let payload: HostAgentXPCWireEventPayload

    fileprivate init(
        eventID: UInt64,
        sentAtUnixMilliseconds: UInt64,
        payload: HostAgentXPCWireEventPayload
    ) throws {
        guard eventID > 0,
              eventID
                <= HostAgentXPCWireEventContract.maximumExactJSONInteger,
              HostAgentXPCWireEventContract.validTimestamp(
                sentAtUnixMilliseconds
              )
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        self.eventID = eventID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        self.payload = payload
    }

    fileprivate init(document: [String: Any]) throws {
        guard Set(document.keys) == Set([
            "eventId", "eventType", "sentAtUnixMilliseconds",
            "payloadLength", "payload",
        ]),
            let eventID = HostAgentXPCWireEventContract.strictUInt64(
                document["eventId"]
            ),
            let eventType = document["eventType"] as? String,
            let sentAt = HostAgentXPCWireEventContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let declaredPayloadLength =
                HostAgentXPCWireEventContract.strictUInt64(
                    document["payloadLength"]
                ),
            let payloadDocument = document["payload"] as? [String: Any]
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        let payload: HostAgentXPCWireEventPayload
        switch eventType {
        case "snapshotChanged":
            guard payloadDocument.isEmpty else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            payload = .snapshotChanged
        case "commandResult":
            payload = .commandResult(try HostAgentXPCWireCommandResult(
                document: payloadDocument
            ))
        default:
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        guard declaredPayloadLength == UInt64(
            try HostAgentXPCWireEventContract.encodePayload(
                payloadDocument
            ).count
        ) else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        try self.init(
            eventID: eventID,
            sentAtUnixMilliseconds: sentAt,
            payload: payload
        )
    }

    fileprivate var document: [String: Any] {
        get throws {
            let eventType: String
            let payloadDocument: [String: Any]
            switch payload {
            case .snapshotChanged:
                eventType = "snapshotChanged"
                payloadDocument = [:]
            case .commandResult(let result):
                eventType = "commandResult"
                payloadDocument = result.document
            }
            return [
                "eventId": eventID,
                "eventType": eventType,
                "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
                "payloadLength": UInt64(
                    try HostAgentXPCWireEventContract.encodePayload(
                        payloadDocument
                    ).count
                ),
                "payload": payloadDocument,
            ]
        }
    }
}

/// Strict Data-only event cursor contract. It deliberately has no Objective-C
/// selector, listener, connection, callback proxy, URL, or raw Core envelope.
package enum HostAgentXPCWireEventContract {
    package static let currentSchemaVersion: UInt64 = 1
    package static let maximumDocumentBytes = 64 * 1_024
    package static let maximumEventCount = 64

    fileprivate static let maximumExactJSONInteger: UInt64 =
        9_007_199_254_740_991
    private static let stateInvalidatingEventTypes: Set<String> = [
        "snapshotChanged",
        "backgroundAgentOperationProgress",
        "incomingConnectionRequest",
        "incomingConnectionRequested",
        "incomingConnectionResolved",
        "incomingConnectionExpired",
        "sessionStarted",
        "sessionCapabilitiesChanged",
        "sessionStatsUpdated",
        "sessionEnded",
        "permissionChanged",
        "recoverableError",
        "fatalError",
    ]
    private static let agentOnlyEventTypes: Set<String> = [
        "mediaControl",
        "mediaDiagnostic",
        "mediaQueueDiagnostic",
        "mediaWriterDiagnostic",
        "mediaNetworkDiagnostic",
        "mediaTransportDiagnostic",
    ]

    fileprivate static func decodeDocument(_ data: Data) throws
        -> [String: Any]
    {
        guard !data.isEmpty else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireEventDocumentError.documentTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        guard let document = value as? [String: Any] else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        return document
    }

    fileprivate static func encodeDocument(_ document: [String: Any]) throws
        -> Data
    {
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: document,
                options: [.sortedKeys]
            )
        } catch {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireEventDocumentError.documentTooLarge
        }
        return data
    }

    fileprivate static func encodePayload(_ payload: Any) throws -> Data {
        do {
            return try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        } catch {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
    }

    fileprivate static func strictUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double <= Double(maximumExactJSONInteger),
              double.rounded(.towardZero) == double
        else { return nil }
        return number.uint64Value
    }

    fileprivate static func strictInt(_ value: Any?) -> Int? {
        guard let value = strictUInt64(value), value <= UInt64(Int.max)
        else { return nil }
        return Int(value)
    }

    fileprivate static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    fileprivate static func validTimestamp(_ value: UInt64) -> Bool {
        value > 0 && value <= maximumExactJSONInteger
    }

    fileprivate static func validToken(_ value: String) -> Bool {
        HostAgentXPCWireHandshakeContract.validIdentifier(value)
    }

    fileprivate static func decodeSchemaVersion(
        _ document: [String: Any]
    ) throws {
        guard let schemaVersion = strictUInt64(document["schemaVersion"])
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        guard schemaVersion == currentSchemaVersion else {
            throw HostAgentXPCWireEventDocumentError.unsupportedSchema(
                schemaVersion
            )
        }
    }

    fileprivate static func project(
        _ record: HostAgentEventRecord,
        expectedHostInstanceID: String
    ) throws -> EventProjection {
        guard let envelope = try? StrictCoreEventEnvelope(record: record)
        else { return .requiresSnapshot }
        guard record.event.hostInstanceId == expectedHostInstanceID else {
            return .requiresSnapshot
        }
        if stateInvalidatingEventTypes.contains(envelope.eventType) {
            return .event(try HostAgentXPCWireEvent(
                eventID: record.sequence,
                sentAtUnixMilliseconds: envelope.sentAtUnixMilliseconds,
                payload: .snapshotChanged
            ))
        }
        if agentOnlyEventTypes.contains(envelope.eventType) {
            return .suppressed
        }
        if envelope.eventType == "commandResult" {
            guard let result = try? HostAgentXPCWireCommandResult(
                document: envelope.payload
            ) else { return .requiresSnapshot }
            return .event(try HostAgentXPCWireEvent(
                eventID: record.sequence,
                sentAtUnixMilliseconds: envelope.sentAtUnixMilliseconds,
                payload: .commandResult(result)
            ))
        }
        return .requiresSnapshot
    }

    fileprivate enum EventProjection {
        case event(HostAgentXPCWireEvent)
        case suppressed
        case requiresSnapshot
    }

    private struct StrictCoreEventEnvelope {
        let eventType: String
        let sentAtUnixMilliseconds: UInt64
        let payload: [String: Any]

        init(record: HostAgentEventRecord) throws {
            guard let value = try? JSONSerialization.jsonObject(
                    with: record.event.rawJSON
                  ),
                  let document = value as? [String: Any],
                  Set(document.keys) == Set([
                    "schemaVersion", "eventId", "eventType",
                    "hostInstanceId", "sentAt", "payload",
                  ]),
                  strictUInt64(document["schemaVersion"]) == 1,
                  strictUInt64(document["eventId"]) == record.event.eventId,
                  let eventType = document["eventType"] as? String,
                  eventType == record.event.eventType,
                  let hostInstanceID = document["hostInstanceId"] as? String,
                  hostInstanceID == record.event.hostInstanceId,
                  let sentAt = strictUInt64(document["sentAt"]),
                  sentAt == record.event.sentAt,
                  validTimestamp(sentAt),
                  let payload = document["payload"] as? [String: Any]
            else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            self.eventType = eventType
            sentAtUnixMilliseconds = sentAt
            self.payload = payload
        }
    }
}

package struct HostAgentXPCWireEventCursorRequest: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let wireVersion: UInt64
    package let requestID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let payloadLength: UInt64
    package let afterEventID: UInt64
    package let maximumEventCount: Int

    package init(
        requestID: String,
        wireVersion: UInt64,
        hostInstanceID: String,
        agentBootID: String,
        afterEventID: UInt64,
        maximumEventCount: Int,
        sentAtUnixMilliseconds: UInt64
    ) throws {
        guard wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              afterEventID
                <= HostAgentXPCWireEventContract.maximumExactJSONInteger,
              (1...HostAgentXPCWireEventContract.maximumEventCount)
                .contains(maximumEventCount),
              HostAgentXPCWireEventContract.validTimestamp(
                sentAtUnixMilliseconds
              )
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        let payload = Self.payloadDocument(
            afterEventID: afterEventID,
            maximumEventCount: maximumEventCount
        )
        schemaVersion = HostAgentXPCWireEventContract.currentSchemaVersion
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        payloadLength = UInt64(
            try HostAgentXPCWireEventContract.encodePayload(payload).count
        )
        self.afterEventID = afterEventID
        self.maximumEventCount = maximumEventCount
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireEventContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "hostInstanceId", "agentBootId", "sentAtUnixMilliseconds",
            "payloadLength", "payload",
        ]),
            document["messageType"] as? String == "eventCursorRequest",
            let wireVersion = HostAgentXPCWireEventContract.strictUInt64(
                document["wireVersion"]
            ),
            let requestID = document["requestId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAt = HostAgentXPCWireEventContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let declaredPayloadLength =
                HostAgentXPCWireEventContract.strictUInt64(
                    document["payloadLength"]
                ),
            let payload = document["payload"] as? [String: Any],
            Set(payload.keys) == Set([
                "afterEventId", "maximumEventCount",
            ]),
            let afterEventID = HostAgentXPCWireEventContract.strictUInt64(
                payload["afterEventId"]
            ),
            let maximumEventCount = HostAgentXPCWireEventContract.strictInt(
                payload["maximumEventCount"]
            )
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        try HostAgentXPCWireEventContract.decodeSchemaVersion(document)
        let request = try Self(
            requestID: requestID,
            wireVersion: wireVersion,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            afterEventID: afterEventID,
            maximumEventCount: maximumEventCount,
            sentAtUnixMilliseconds: sentAt
        )
        guard declaredPayloadLength == request.payloadLength else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        return request
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireEventContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "eventCursorRequest",
            "requestId": requestID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "payloadLength": payloadLength,
            "payload": Self.payloadDocument(
                afterEventID: afterEventID,
                maximumEventCount: maximumEventCount
            ),
        ])
    }

    private static func payloadDocument(
        afterEventID: UInt64,
        maximumEventCount: Int
    ) -> [String: Any] {
        [
            "afterEventId": afterEventID,
            "maximumEventCount": maximumEventCount,
        ]
    }
}

package struct HostAgentXPCWireEventCursorResponse: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let wireVersion: UInt64
    package let requestID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let payloadLength: UInt64
    package let outcome: HostAgentXPCWireEventOutcome
    package let firstAvailableEventID: UInt64?
    package let latestEventID: UInt64
    package let resumeAfterEventID: UInt64?
    package let hasMore: Bool
    package let events: [HostAgentXPCWireEvent]

    private init(
        requestID: String,
        wireVersion: UInt64,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64,
        outcome: HostAgentXPCWireEventOutcome,
        firstAvailableEventID: UInt64?,
        latestEventID: UInt64,
        resumeAfterEventID: UInt64?,
        hasMore: Bool,
        events: [HostAgentXPCWireEvent],
        declaredPayloadLength: UInt64? = nil
    ) throws {
        guard wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              HostAgentXPCWireEventContract.validTimestamp(
                sentAtUnixMilliseconds
              ),
              latestEventID
                <= HostAgentXPCWireEventContract.maximumExactJSONInteger,
              events.count <= HostAgentXPCWireEventContract.maximumEventCount,
              Self.validShape(
                outcome: outcome,
                firstAvailableEventID: firstAvailableEventID,
                latestEventID: latestEventID,
                resumeAfterEventID: resumeAfterEventID,
                hasMore: hasMore,
                events: events
              )
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        let payload = try Self.payloadDocument(
            outcome: outcome,
            firstAvailableEventID: firstAvailableEventID,
            latestEventID: latestEventID,
            resumeAfterEventID: resumeAfterEventID,
            hasMore: hasMore,
            events: events
        )
        let payloadLength = UInt64(
            try HostAgentXPCWireEventContract.encodePayload(payload).count
        )
        guard declaredPayloadLength == nil
                || declaredPayloadLength == payloadLength
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        schemaVersion = HostAgentXPCWireEventContract.currentSchemaVersion
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        self.payloadLength = payloadLength
        self.outcome = outcome
        self.firstAvailableEventID = firstAvailableEventID
        self.latestEventID = latestEventID
        self.resumeAfterEventID = resumeAfterEventID
        self.hasMore = hasMore
        self.events = events
    }

    package static func make(
        for request: HostAgentXPCWireEventCursorRequest,
        identity: HostAgentXPCWireAgentIdentity,
        replay: HostAgentEventReplayResult,
        sentAtUnixMilliseconds: UInt64
    ) throws -> Self {
        guard request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        switch replay {
        case .upToDate(let latestSequence):
            guard latestSequence == request.afterEventID else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            return try terminal(
                for: request,
                identity: identity,
                sentAtUnixMilliseconds: sentAtUnixMilliseconds,
                outcome: .upToDate,
                latestEventID: latestSequence
            )
        case .gap(let firstAvailableSequence, let latestSequence):
            guard request.afterEventID < latestSequence,
                  request.afterEventID <
                    HostAgentXPCWireEventContract.maximumExactJSONInteger,
                  request.afterEventID + 1 < firstAvailableSequence,
                  firstAvailableSequence <= latestSequence
            else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            return try Self(
                requestID: request.requestID,
                wireVersion: request.wireVersion,
                hostInstanceID: identity.hostInstanceID,
                agentBootID: identity.agentBootID,
                sentAtUnixMilliseconds: sentAtUnixMilliseconds,
                outcome: .gap,
                firstAvailableEventID: firstAvailableSequence,
                latestEventID: latestSequence,
                resumeAfterEventID: nil,
                hasMore: false,
                events: []
            )
        case .invalidCursor(let latestSequence):
            guard request.afterEventID > latestSequence else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            return try terminal(
                for: request,
                identity: identity,
                sentAtUnixMilliseconds: sentAtUnixMilliseconds,
                outcome: .invalidCursor,
                latestEventID: latestSequence
            )
        case .batch(let records, let latestSequence, let hasMore):
            guard Self.validReplayBatch(
                records,
                latestSequence: latestSequence,
                hasMore: hasMore,
                request: request
            ) else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            var events: [HostAgentXPCWireEvent] = []
            for record in records {
                switch try HostAgentXPCWireEventContract.project(
                    record,
                    expectedHostInstanceID: identity.hostInstanceID
                ) {
                case .suppressed:
                    continue
                case .requiresSnapshot:
                    return try terminal(
                        for: request,
                        identity: identity,
                        sentAtUnixMilliseconds: sentAtUnixMilliseconds,
                        outcome: .resnapshotRequired,
                        latestEventID: latestSequence
                    )
                case .event(let event):
                    if case .snapshotChanged = event.payload,
                       case .snapshotChanged? = events.last?.payload
                    {
                        events[events.count - 1] = event
                    } else {
                        events.append(event)
                    }
                }
            }
            return try Self(
                requestID: request.requestID,
                wireVersion: request.wireVersion,
                hostInstanceID: identity.hostInstanceID,
                agentBootID: identity.agentBootID,
                sentAtUnixMilliseconds: sentAtUnixMilliseconds,
                outcome: .batch,
                firstAvailableEventID: nil,
                latestEventID: latestSequence,
                resumeAfterEventID: records.last?.sequence,
                hasMore: hasMore,
                events: events
            )
        }
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireEventContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "hostInstanceId", "agentBootId", "sentAtUnixMilliseconds",
            "payloadLength", "payload",
        ]),
            document["messageType"] as? String == "eventCursorResponse",
            let wireVersion = HostAgentXPCWireEventContract.strictUInt64(
                document["wireVersion"]
            ),
            let requestID = document["requestId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAt = HostAgentXPCWireEventContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let declaredPayloadLength =
                HostAgentXPCWireEventContract.strictUInt64(
                    document["payloadLength"]
                ),
            let payload = document["payload"] as? [String: Any],
            Set(payload.keys) == Set([
                "outcome", "firstAvailableEventId", "latestEventId",
                "resumeAfterEventId", "hasMore", "events",
            ]),
            let rawOutcome = payload["outcome"] as? String,
            let outcome = HostAgentXPCWireEventOutcome(rawValue: rawOutcome),
            let firstAvailableEventID = optionalUInt64(
                payload["firstAvailableEventId"]
            ),
            let latestEventID = HostAgentXPCWireEventContract.strictUInt64(
                payload["latestEventId"]
            ),
            let resumeAfterEventID = optionalUInt64(
                payload["resumeAfterEventId"]
            ),
            let hasMore = HostAgentXPCWireEventContract.strictBool(
                payload["hasMore"]
            ),
            let rawEvents = payload["events"] as? [Any],
            rawEvents.count <= HostAgentXPCWireEventContract.maximumEventCount
        else {
            throw HostAgentXPCWireEventDocumentError.invalidDocument
        }
        let events = try rawEvents.map { value -> HostAgentXPCWireEvent in
            guard let document = value as? [String: Any] else {
                throw HostAgentXPCWireEventDocumentError.invalidDocument
            }
            return try HostAgentXPCWireEvent(document: document)
        }
        try HostAgentXPCWireEventContract.decodeSchemaVersion(document)
        return try Self(
            requestID: requestID,
            wireVersion: wireVersion,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAt,
            outcome: outcome,
            firstAvailableEventID: firstAvailableEventID,
            latestEventID: latestEventID,
            resumeAfterEventID: resumeAfterEventID,
            hasMore: hasMore,
            events: events,
            declaredPayloadLength: declaredPayloadLength
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireEventContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "eventCursorResponse",
            "requestId": requestID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "payloadLength": payloadLength,
            "payload": try Self.payloadDocument(
                outcome: outcome,
                firstAvailableEventID: firstAvailableEventID,
                latestEventID: latestEventID,
                resumeAfterEventID: resumeAfterEventID,
                hasMore: hasMore,
                events: events
            ),
        ])
    }

    package func evaluate(
        for request: HostAgentXPCWireEventCursorRequest
    ) -> HostAgentXPCWireEventEvaluation {
        guard requestID == request.requestID,
              wireVersion == request.wireVersion,
              hostInstanceID == request.hostInstanceID,
              agentBootID == request.agentBootID
        else { return .invalidResponse }
        switch outcome {
        case .upToDate:
            guard latestEventID == request.afterEventID else {
                return .invalidResponse
            }
        case .batch:
            guard let resumeAfterEventID,
                  resumeAfterEventID > request.afterEventID,
                  events.count <= request.maximumEventCount,
                  events.allSatisfy({
                    $0.eventID > request.afterEventID
                        && $0.eventID <= resumeAfterEventID
                  })
            else { return .invalidResponse }
        case .gap:
            guard let firstAvailableEventID,
                  request.afterEventID
                    < HostAgentXPCWireEventContract.maximumExactJSONInteger,
                  request.afterEventID + 1 < firstAvailableEventID
            else { return .invalidResponse }
        case .invalidCursor:
            guard request.afterEventID > latestEventID else {
                return .invalidResponse
            }
        case .resnapshotRequired:
            guard request.afterEventID < latestEventID else {
                return .invalidResponse
            }
        }
        return .correlated
    }

    private static func terminal(
        for request: HostAgentXPCWireEventCursorRequest,
        identity: HostAgentXPCWireAgentIdentity,
        sentAtUnixMilliseconds: UInt64,
        outcome: HostAgentXPCWireEventOutcome,
        latestEventID: UInt64
    ) throws -> Self {
        try Self(
            requestID: request.requestID,
            wireVersion: request.wireVersion,
            hostInstanceID: identity.hostInstanceID,
            agentBootID: identity.agentBootID,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds,
            outcome: outcome,
            firstAvailableEventID: nil,
            latestEventID: latestEventID,
            resumeAfterEventID: nil,
            hasMore: false,
            events: []
        )
    }

    private static func validReplayBatch(
        _ records: [HostAgentEventRecord],
        latestSequence: UInt64,
        hasMore: Bool,
        request: HostAgentXPCWireEventCursorRequest
    ) -> Bool {
        guard !records.isEmpty,
              records.count <= request.maximumEventCount,
              request.afterEventID
                < HostAgentXPCWireEventContract.maximumExactJSONInteger,
              records.first?.sequence == request.afterEventID + 1,
              let lastSequence = records.last?.sequence,
              lastSequence <= latestSequence,
              hasMore == (lastSequence < latestSequence)
        else { return false }
        var expected = request.afterEventID + 1
        for record in records {
            guard record.sequence == expected else { return false }
            expected += 1
        }
        return true
    }

    private static func validShape(
        outcome: HostAgentXPCWireEventOutcome,
        firstAvailableEventID: UInt64?,
        latestEventID: UInt64,
        resumeAfterEventID: UInt64?,
        hasMore: Bool,
        events: [HostAgentXPCWireEvent]
    ) -> Bool {
        let eventIDs = events.map(\.eventID)
        guard eventIDs == eventIDs.sorted(),
              Set(eventIDs).count == eventIDs.count
        else { return false }
        switch outcome {
        case .upToDate, .invalidCursor, .resnapshotRequired:
            return firstAvailableEventID == nil
                && resumeAfterEventID == nil
                && !hasMore
                && events.isEmpty
        case .gap:
            guard let firstAvailableEventID else { return false }
            return firstAvailableEventID > 0
                && firstAvailableEventID <= latestEventID
                && resumeAfterEventID == nil
                && !hasMore
                && events.isEmpty
        case .batch:
            guard firstAvailableEventID == nil,
                  let resumeAfterEventID,
                  resumeAfterEventID > 0,
                  resumeAfterEventID <= latestEventID,
                  hasMore == (resumeAfterEventID < latestEventID)
            else { return false }
            return events.allSatisfy { $0.eventID <= resumeAfterEventID }
        }
    }

    private static func payloadDocument(
        outcome: HostAgentXPCWireEventOutcome,
        firstAvailableEventID: UInt64?,
        latestEventID: UInt64,
        resumeAfterEventID: UInt64?,
        hasMore: Bool,
        events: [HostAgentXPCWireEvent]
    ) throws -> [String: Any] {
        [
            "outcome": outcome.rawValue,
            "firstAvailableEventId": firstAvailableEventID ?? NSNull(),
            "latestEventId": latestEventID,
            "resumeAfterEventId": resumeAfterEventID ?? NSNull(),
            "hasMore": hasMore,
            "events": try events.map { try $0.document },
        ]
    }

    private static func optionalUInt64(_ value: Any?) -> UInt64?? {
        if value is NSNull { return .some(nil) }
        guard let value = HostAgentXPCWireEventContract.strictUInt64(value)
        else { return nil }
        return .some(value)
    }
}
