import CoreFoundation
import Foundation

package enum HostAgentXPCPasswordAction: String, Equatable, Sendable {
    case revealTemporaryPassword
    case regenerateTemporaryPassword
    case setPermanentPassword
    case clearPermanentPassword
}

package enum HostAgentXPCPasswordStatus: String, Equatable, Sendable {
    case ok
    case rejected
    case error
}

package enum HostAgentXPCPasswordDetail: String, Equatable, Sendable {
    case none
    case busy
    case duplicateRequest
    case coreUnavailable
    case coreFailure
    case temporaryPasswordUnavailable
    case empty
    case tooShort
    case tooLong
    case outerWhitespace
    case invalidCharacters
    case changeDisabled
    case storageFailure
}

package enum HostAgentXPCWirePasswordError: Error, Equatable {
    case invalidDocument
    case documentTooLarge
}

package enum HostAgentXPCWirePasswordContract {
    package static let schemaVersion: UInt64 = 1
    package static let maximumDocumentBytes = 8 * 1_024
    package static let maximumSecretBytes = 1_024

    fileprivate static func decode(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw HostAgentXPCWirePasswordError.invalidDocument }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWirePasswordError.documentTooLarge
        }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let document = value as? [String: Any]
        else { throw HostAgentXPCWirePasswordError.invalidDocument }
        return document
    }

    fileprivate static func encode(_ document: [String: Any]) throws -> Data {
        guard let data = try? JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        ) else { throw HostAgentXPCWirePasswordError.invalidDocument }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWirePasswordError.documentTooLarge
        }
        return data
    }

    fileprivate static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0,
              value <= 9_007_199_254_740_991,
              value.rounded(.towardZero) == value
        else { return nil }
        return number.uint64Value
    }
}

package struct HostAgentXPCWirePasswordRequest: Equatable, Sendable {
    package let wireVersion: UInt64
    package let requestID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let action: HostAgentXPCPasswordAction
    package let secretLength: UInt64

    package init(
        wireVersion: UInt64,
        requestID: String,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64,
        action: HostAgentXPCPasswordAction,
        secretLength: UInt64
    ) throws {
        let expectsSecret = action == .setPermanentPassword
        guard wireVersion == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              sentAtUnixMilliseconds > 0,
              sentAtUnixMilliseconds <= 9_007_199_254_740_991,
              expectsSecret
                ? (1...UInt64(HostAgentXPCWirePasswordContract.maximumSecretBytes))
                    .contains(secretLength)
                : secretLength == 0
        else { throw HostAgentXPCWirePasswordError.invalidDocument }
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        self.action = action
        self.secretLength = secretLength
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWirePasswordContract.encode([
            "schemaVersion": HostAgentXPCWirePasswordContract.schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "passwordRequest",
            "requestId": requestID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "action": action.rawValue,
            "secretLength": secretLength,
        ])
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWirePasswordContract.decode(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "hostInstanceId", "agentBootId", "sentAtUnixMilliseconds",
            "action", "secretLength",
        ]),
              HostAgentXPCWirePasswordContract.uint64(document["schemaVersion"])
                == HostAgentXPCWirePasswordContract.schemaVersion,
              document["messageType"] as? String == "passwordRequest",
              let wireVersion = HostAgentXPCWirePasswordContract.uint64(document["wireVersion"]),
              let requestID = document["requestId"] as? String,
              let hostInstanceID = document["hostInstanceId"] as? String,
              let agentBootID = document["agentBootId"] as? String,
              let sentAt = HostAgentXPCWirePasswordContract.uint64(
                document["sentAtUnixMilliseconds"]
              ),
              let rawAction = document["action"] as? String,
              let action = HostAgentXPCPasswordAction(rawValue: rawAction),
              let secretLength = HostAgentXPCWirePasswordContract.uint64(
                document["secretLength"]
              )
        else { throw HostAgentXPCWirePasswordError.invalidDocument }
        return try Self(
            wireVersion: wireVersion,
            requestID: requestID,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAt,
            action: action,
            secretLength: secretLength
        )
    }
}

package struct HostAgentXPCWirePasswordResponse: Equatable, Sendable {
    package let requestID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let action: HostAgentXPCPasswordAction
    package let status: HostAgentXPCPasswordStatus
    package let detail: HostAgentXPCPasswordDetail
    package let secretLength: UInt64

    package init(
        request: HostAgentXPCWirePasswordRequest,
        status: HostAgentXPCPasswordStatus,
        detail: HostAgentXPCPasswordDetail,
        secretLength: UInt64
    ) throws {
        guard secretLength <= UInt64(HostAgentXPCWirePasswordContract.maximumSecretBytes),
              (request.action == .revealTemporaryPassword && status == .ok)
                ? secretLength > 0
                : secretLength == 0,
              (status == .ok) == (detail == .none)
        else { throw HostAgentXPCWirePasswordError.invalidDocument }
        requestID = request.requestID
        hostInstanceID = request.hostInstanceID
        agentBootID = request.agentBootID
        action = request.action
        self.status = status
        self.detail = detail
        self.secretLength = secretLength
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWirePasswordContract.encode([
            "schemaVersion": HostAgentXPCWirePasswordContract.schemaVersion,
            "messageType": "passwordResponse",
            "requestId": requestID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "action": action.rawValue,
            "status": status.rawValue,
            "detail": detail.rawValue,
            "secretLength": secretLength,
        ])
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWirePasswordContract.decode(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "messageType", "requestId", "hostInstanceId",
            "agentBootId", "action", "status", "detail", "secretLength",
        ]),
              HostAgentXPCWirePasswordContract.uint64(document["schemaVersion"])
                == HostAgentXPCWirePasswordContract.schemaVersion,
              document["messageType"] as? String == "passwordResponse",
              let requestID = document["requestId"] as? String,
              let hostInstanceID = document["hostInstanceId"] as? String,
              let agentBootID = document["agentBootId"] as? String,
              let rawAction = document["action"] as? String,
              let action = HostAgentXPCPasswordAction(rawValue: rawAction),
              let rawStatus = document["status"] as? String,
              let status = HostAgentXPCPasswordStatus(rawValue: rawStatus),
              let rawDetail = document["detail"] as? String,
              let detail = HostAgentXPCPasswordDetail(rawValue: rawDetail),
              let secretLength = HostAgentXPCWirePasswordContract.uint64(
                document["secretLength"]
              )
        else { throw HostAgentXPCWirePasswordError.invalidDocument }
        let request = try HostAgentXPCWirePasswordRequest(
            wireVersion: HostAgentXPCWireHandshakeContract.currentWireVersion,
            requestID: requestID,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: 1,
            action: action,
            secretLength: action == .setPermanentPassword ? 1 : 0
        )
        return try Self(
            request: request,
            status: status,
            detail: detail,
            secretLength: secretLength
        )
    }

    package func isCorrelated(to request: HostAgentXPCWirePasswordRequest) -> Bool {
        requestID == request.requestID
            && hostInstanceID == request.hostInstanceID
            && agentBootID == request.agentBootID
            && action == request.action
    }
}
