import CoreFoundation
import Foundation

package enum HostAgentXPCWireCommandDocumentError: Error, Equatable {
    case invalidDocument
    case documentTooLarge
    case unsupportedSchema(UInt64)
}

package enum HostAgentXPCWireCommandEvaluation: Equatable, Sendable {
    case correlated
    case invalidResponse
}

package enum HostAgentXPCWireCommandAcceptance:
    String,
    Equatable,
    Sendable
{
    case queued
}

package enum HostAgentXPCWireCommandName:
    String,
    CaseIterable,
    Equatable,
    Sendable
{
    case approveIncoming
    case rejectIncoming
    case disableInputForActiveSession
    case disableClipboardReadForActiveSession
    case disableClipboardWriteForActiveSession
    case disableClipboardForActiveSession
    case disableAudioForActiveSession
    case disconnectSession
}

/// Strict Data-only command envelope for approval and active-session actions.
/// No selector, runtime service, queue, or execution authority is defined here.
package enum HostAgentXPCWireCommandContract {
    package static let currentSchemaVersion: UInt64 = 2
    package static let maximumDocumentBytes = 16 * 1_024

    fileprivate static let maximumExactJSONInteger: UInt64 =
        9_007_199_254_740_991
    private static let maximumConnectionIDBytes = 128
    private static let connectionIDPunctuation = ".-_+:".unicodeScalars

    fileprivate static func decodeDocument(_ data: Data) throws
        -> [String: Any]
    {
        guard !data.isEmpty else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireCommandDocumentError.documentTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        guard let document = value as? [String: Any] else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
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
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireCommandDocumentError.documentTooLarge
        }
        return data
    }

    fileprivate static func encodePayload(_ payload: [String: Any]) throws
        -> Data
    {
        do {
            return try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        } catch {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
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

    fileprivate static func validTimestamp(_ value: UInt64) -> Bool {
        value > 0 && value <= maximumExactJSONInteger
    }

    fileprivate static func decodeSchemaVersion(
        _ document: [String: Any]
    ) throws {
        guard let schemaVersion = strictUInt64(document["schemaVersion"])
        else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        guard schemaVersion == currentSchemaVersion else {
            throw HostAgentXPCWireCommandDocumentError.unsupportedSchema(
                schemaVersion
            )
        }
    }

    fileprivate static func validConnectionID(
        _ value: String,
        hostInstanceID: String
    ) -> Bool {
        let prefix = "\(hostInstanceID):"
        guard value.utf8.count <= maximumConnectionIDBytes,
              value.hasPrefix(prefix),
              value.utf8.count > prefix.utf8.count
        else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || connectionIDPunctuation.contains($0)
        }
    }
}

package struct HostAgentXPCWireCommandRequest: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let wireVersion: UInt64
    package let requestID: String
    package let commandID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let payloadLength: UInt64
    package let name: HostAgentXPCWireCommandName
    package let connectionID: String

    package init(
        requestID: String,
        commandID: String,
        wireVersion: UInt64,
        hostInstanceID: String,
        agentBootID: String,
        name: HostAgentXPCWireCommandName,
        connectionID: String,
        sentAtUnixMilliseconds: UInt64
    ) throws {
        guard wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(commandID),
              HostAgentXPCWireHandshakeContract.validIdentifier(
                hostInstanceID
              ),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              HostAgentXPCWireCommandContract.validConnectionID(
                connectionID,
                hostInstanceID: hostInstanceID
              ),
              HostAgentXPCWireCommandContract.validTimestamp(
                sentAtUnixMilliseconds
              )
        else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        let payload = Self.payloadDocument(
            name: name,
            connectionID: connectionID
        )
        schemaVersion = HostAgentXPCWireCommandContract.currentSchemaVersion
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.commandID = commandID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        payloadLength = UInt64(
            try HostAgentXPCWireCommandContract.encodePayload(payload).count
        )
        self.name = name
        self.connectionID = connectionID
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireCommandContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "commandId", "hostInstanceId", "agentBootId",
            "sentAtUnixMilliseconds", "payloadLength", "payload",
        ]),
            document["messageType"] as? String == "commandRequest",
            let wireVersion = HostAgentXPCWireCommandContract.strictUInt64(
                document["wireVersion"]
            ),
            let requestID = document["requestId"] as? String,
            let commandID = document["commandId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAt = HostAgentXPCWireCommandContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let declaredPayloadLength =
                HostAgentXPCWireCommandContract.strictUInt64(
                    document["payloadLength"]
                ),
            let payload = document["payload"] as? [String: Any],
            Set(payload.keys) == Set(["name", "connectionId"]),
            let rawName = payload["name"] as? String,
            let name = HostAgentXPCWireCommandName(rawValue: rawName),
            let connectionID = payload["connectionId"] as? String,
            declaredPayloadLength == UInt64(
                try HostAgentXPCWireCommandContract.encodePayload(payload).count
            )
        else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        try HostAgentXPCWireCommandContract.decodeSchemaVersion(document)
        return try Self(
            requestID: requestID,
            commandID: commandID,
            wireVersion: wireVersion,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            name: name,
            connectionID: connectionID,
            sentAtUnixMilliseconds: sentAt
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireCommandContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "commandRequest",
            "requestId": requestID,
            "commandId": commandID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "payloadLength": payloadLength,
            "payload": Self.payloadDocument(
                name: name,
                connectionID: connectionID
            ),
        ])
    }

    private static func payloadDocument(
        name: HostAgentXPCWireCommandName,
        connectionID: String
    ) -> [String: Any] {
        [
            "name": name.rawValue,
            "connectionId": connectionID,
        ]
    }
}

package struct HostAgentXPCWireCommandAcceptedResponse:
    Equatable,
    Sendable
{
    package let schemaVersion: UInt64
    package let wireVersion: UInt64
    package let requestID: String
    package let commandID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let payloadLength: UInt64
    package let acceptance: HostAgentXPCWireCommandAcceptance

    private init(
        requestID: String,
        commandID: String,
        wireVersion: UInt64,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64
    ) throws {
        guard wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(commandID),
              HostAgentXPCWireHandshakeContract.validIdentifier(
                hostInstanceID
              ),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              HostAgentXPCWireCommandContract.validTimestamp(
                sentAtUnixMilliseconds
              )
        else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        let payload = Self.payloadDocument
        schemaVersion = HostAgentXPCWireCommandContract.currentSchemaVersion
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.commandID = commandID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        payloadLength = UInt64(
            try HostAgentXPCWireCommandContract.encodePayload(payload).count
        )
        acceptance = .queued
    }

    /// Builds an acknowledgement only after the caller has queued the command.
    /// The eventual operation outcome remains an event keyed by `commandID`.
    package static func makeQueued(
        for request: HostAgentXPCWireCommandRequest,
        identity: HostAgentXPCWireAgentIdentity,
        sentAtUnixMilliseconds: UInt64
    ) throws -> Self {
        guard request.wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID
        else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        return try Self(
            requestID: request.requestID,
            commandID: request.commandID,
            wireVersion: request.wireVersion,
            hostInstanceID: identity.hostInstanceID,
            agentBootID: identity.agentBootID,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        )
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireCommandContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "commandId", "hostInstanceId", "agentBootId",
            "sentAtUnixMilliseconds", "payloadLength", "payload",
        ]),
            document["messageType"] as? String == "commandAccepted",
            let wireVersion = HostAgentXPCWireCommandContract.strictUInt64(
                document["wireVersion"]
            ),
            let requestID = document["requestId"] as? String,
            let commandID = document["commandId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAt = HostAgentXPCWireCommandContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let declaredPayloadLength =
                HostAgentXPCWireCommandContract.strictUInt64(
                    document["payloadLength"]
                ),
            let payload = document["payload"] as? [String: Any],
            Set(payload.keys) == Set(["acceptance"]),
            payload["acceptance"] as? String
                == HostAgentXPCWireCommandAcceptance.queued.rawValue,
            declaredPayloadLength == UInt64(
                try HostAgentXPCWireCommandContract.encodePayload(payload).count
            )
        else {
            throw HostAgentXPCWireCommandDocumentError.invalidDocument
        }
        try HostAgentXPCWireCommandContract.decodeSchemaVersion(document)
        return try Self(
            requestID: requestID,
            commandID: commandID,
            wireVersion: wireVersion,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAt
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireCommandContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "commandAccepted",
            "requestId": requestID,
            "commandId": commandID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "payloadLength": payloadLength,
            "payload": Self.payloadDocument,
        ])
    }

    package func evaluate(
        for request: HostAgentXPCWireCommandRequest
    ) -> HostAgentXPCWireCommandEvaluation {
        guard wireVersion == request.wireVersion,
              requestID == request.requestID,
              commandID == request.commandID,
              hostInstanceID == request.hostInstanceID,
              agentBootID == request.agentBootID
        else { return .invalidResponse }
        return .correlated
    }

    private static let payloadDocument: [String: Any] = [
        "acceptance": HostAgentXPCWireCommandAcceptance.queued.rawValue,
    ]
}
