import CoreFoundation
import Foundation

package enum HostAgentXPCWireSnapshotDocumentError: Error, Equatable {
    case invalidDocument
    case documentTooLarge
    case unsupportedSchema(UInt64)
    case snapshotUnavailable
}

package enum HostAgentXPCWireSnapshotEvaluation: Equatable, Sendable {
    case correlated
    case invalidResponse
}

/// Strict, Data-only snapshot-first contract. This file intentionally does not
/// define an Objective-C interface or activate an XPC connection.
package enum HostAgentXPCWireSnapshotContract {
    package static let currentSchemaVersion: UInt64 = 1
    package static let maximumDocumentBytes = 32 * 1_024

    fileprivate static let maximumExactJSONInteger: UInt64 =
        9_007_199_254_740_991
    fileprivate static let maximumStatusBytes = 32
    fileprivate static let maximumLocalIDBytes = 128
    fileprivate static let maximumLastErrorBytes = 4 * 1_024
    fileprivate static let allowedHostStates: Set<String> = [
        "created", "starting", "ready", "stopping", "stopped", "error",
    ]
    fileprivate static let allowedRegistrationStatuses: Set<String> = [
        "notStarted", "pending", "ready", "degraded", "suspending", "suspended",
    ]
    fileprivate static let allowedCapabilities: Set<String> = [
        "viewDisplay", "controlKeyboardMouse", "readClipboard",
        "writeClipboard", "hearSystemAudio",
    ]

    fileprivate static func decodeDocument(_ data: Data) throws
        -> [String: Any]
    {
        guard !data.isEmpty else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireSnapshotDocumentError.documentTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        guard let document = value as? [String: Any] else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
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
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireSnapshotDocumentError.documentTooLarge
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
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
    }

    fileprivate static func decodeSchemaVersion(
        _ document: [String: Any]
    ) throws {
        guard let schemaVersion = strictUInt64(document["schemaVersion"])
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        guard schemaVersion == currentSchemaVersion else {
            throw HostAgentXPCWireSnapshotDocumentError.unsupportedSchema(
                schemaVersion
            )
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
        guard let unsigned = strictUInt64(value), unsigned <= UInt64(Int.max)
        else { return nil }
        return Int(unsigned)
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

    fileprivate static func validText(
        _ value: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool
    ) -> Bool {
        (allowEmpty || !value.isEmpty)
            && value.utf8.count <= maximumUTF8Bytes
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    fileprivate static func validCapabilities(
        _ values: [String],
        requiresClipboardPair: Bool
    ) -> Bool {
        let set = Set(values)
        return (1...16).contains(values.count)
            && set.count == values.count
            && set.contains("viewDisplay")
            && set.isSubset(of: allowedCapabilities)
            && (!requiresClipboardPair
                || set.contains("readClipboard")
                    == set.contains("writeClipboard"))
    }

    fileprivate static func decodeOptionalText(
        _ value: Any?,
        maximumUTF8Bytes: Int
    ) -> String?? {
        if value is NSNull { return .some(nil) }
        guard let text = value as? String,
              validText(
                text,
                maximumUTF8Bytes: maximumUTF8Bytes,
                allowEmpty: false
              )
        else { return nil }
        return .some(text)
    }
}

package struct HostAgentXPCWireSnapshotRequest: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let wireVersion: UInt64
    package let requestID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let payloadLength: UInt64

    package init(
        requestID: String,
        wireVersion: UInt64,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64
    ) throws {
        guard wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              HostAgentXPCWireSnapshotContract.validTimestamp(
                sentAtUnixMilliseconds
              )
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        schemaVersion = HostAgentXPCWireSnapshotContract.currentSchemaVersion
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        payloadLength = UInt64(
            try HostAgentXPCWireSnapshotContract.encodePayload([:]).count
        )
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireSnapshotContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "hostInstanceId", "agentBootId", "sentAtUnixMilliseconds",
            "payloadLength", "payload",
        ]),
            document["messageType"] as? String == "snapshotRequest",
            let wireVersion = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["wireVersion"]
            ),
            let requestID = document["requestId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAt = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let payloadLength = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["payloadLength"]
            ),
            let payload = document["payload"] as? [String: Any],
            payload.isEmpty,
            payloadLength == UInt64(
                try HostAgentXPCWireSnapshotContract.encodePayload(payload).count
            )
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        try HostAgentXPCWireSnapshotContract.decodeSchemaVersion(document)
        return try Self(
            requestID: requestID,
            wireVersion: wireVersion,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAt
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireSnapshotContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "snapshotRequest",
            "requestId": requestID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "payloadLength": payloadLength,
            "payload": [String: Any](),
        ])
    }
}

package struct HostAgentXPCWirePendingApproval: Equatable, Sendable {
    package let connectionID: String
    package let remoteID: String
    package let remoteName: String
    package let remotePlatform: String
    package let requestedAt: UInt64
    package let expiresAt: UInt64
    package let requestedCapabilities: [String]
    package let transport: String
    package let authenticationMethod: String
    package let riskAlerts: [String]

    fileprivate init(_ value: HostPendingApproval) {
        connectionID = value.connectionId
        remoteID = value.remoteId
        remoteName = value.remoteName
        remotePlatform = value.remotePlatform
        requestedAt = value.requestedAt
        expiresAt = value.expiresAt
        requestedCapabilities = value.requestedCapabilities
        transport = value.transport
        authenticationMethod = value.authenticationMethod
        riskAlerts = value.riskAlerts
    }

    fileprivate init(document: [String: Any]) throws {
        guard Set(document.keys) == Set([
            "connectionId", "remoteId", "remoteName", "remotePlatform",
            "remoteMetadataTrust", "requestedAt", "expiresAt",
            "requestedCapabilities", "transport", "authenticationMethod",
            "riskAlerts",
        ]),
            let connectionID = document["connectionId"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                connectionID, maximumUTF8Bytes: 128, allowEmpty: false
            ),
            let remoteID = document["remoteId"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                remoteID, maximumUTF8Bytes: 256, allowEmpty: false
            ),
            let remoteName = document["remoteName"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                remoteName, maximumUTF8Bytes: 256, allowEmpty: true
            ),
            let remotePlatform = document["remotePlatform"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                remotePlatform, maximumUTF8Bytes: 256, allowEmpty: true
            ),
            document["remoteMetadataTrust"] as? String == "untrusted",
            let requestedAt = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["requestedAt"]
            ),
            HostAgentXPCWireSnapshotContract.validTimestamp(requestedAt),
            let expiresAt = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["expiresAt"]
            ),
            expiresAt > requestedAt,
            let capabilities = document["requestedCapabilities"] as? [String],
            HostAgentXPCWireSnapshotContract.validCapabilities(
                capabilities,
                requiresClipboardPair: false
            ),
            let transport = document["transport"] as? String,
            ["direct", "relay", "unknown"].contains(transport),
            document["authenticationMethod"] as? String == "localApproval",
            let riskAlerts = document["riskAlerts"] as? [String],
            riskAlerts.isEmpty
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        self.connectionID = connectionID
        self.remoteID = remoteID
        self.remoteName = remoteName
        self.remotePlatform = remotePlatform
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        requestedCapabilities = capabilities
        self.transport = transport
        authenticationMethod = "localApproval"
        self.riskAlerts = riskAlerts
    }

    fileprivate var document: [String: Any] {
        [
            "connectionId": connectionID,
            "remoteId": remoteID,
            "remoteName": remoteName,
            "remotePlatform": remotePlatform,
            "remoteMetadataTrust": "untrusted",
            "requestedAt": requestedAt,
            "expiresAt": expiresAt,
            "requestedCapabilities": requestedCapabilities,
            "transport": transport,
            "authenticationMethod": authenticationMethod,
            "riskAlerts": riskAlerts,
        ]
    }
}

package struct HostAgentXPCWireActiveSession: Equatable, Sendable {
    package let connectionID: String
    package let remoteID: String
    package let remoteName: String
    package let remotePlatform: String
    package let startedAt: UInt64
    package let initialCapabilities: [String]
    package let activeCapabilities: [String]
    package let inputAvailability: HostSessionInputAvailability
    package let inputUnavailableReason: HostSessionInputUnavailableReason?

    fileprivate init(_ value: HostActiveSession) {
        connectionID = value.connectionId
        remoteID = value.remoteId
        remoteName = value.remoteName
        remotePlatform = value.remotePlatform
        startedAt = value.startedAt
        initialCapabilities = value.initialCapabilities
        activeCapabilities = value.activeCapabilities
        inputAvailability = value.inputAvailability
        inputUnavailableReason = value.inputUnavailableReason
    }

    fileprivate init(document: [String: Any], hostInstanceID: String) throws {
        guard Set(document.keys) == Set([
            "connectionId", "remoteId", "remoteName", "remotePlatform",
            "remoteMetadataTrust", "startedAt", "initialCapabilities",
            "activeCapabilities", "inputAvailability",
            "inputUnavailableReason",
        ]),
            let connectionID = document["connectionId"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                connectionID, maximumUTF8Bytes: 128, allowEmpty: false
            ),
            connectionID.hasPrefix("\(hostInstanceID):"),
            let remoteID = document["remoteId"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                remoteID, maximumUTF8Bytes: 256, allowEmpty: false
            ),
            let remoteName = document["remoteName"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                remoteName, maximumUTF8Bytes: 256, allowEmpty: true
            ),
            let remotePlatform = document["remotePlatform"] as? String,
            HostAgentXPCWireSnapshotContract.validText(
                remotePlatform, maximumUTF8Bytes: 256, allowEmpty: true
            ),
            document["remoteMetadataTrust"] as? String == "untrusted",
            let startedAt = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["startedAt"]
            ),
            HostAgentXPCWireSnapshotContract.validTimestamp(startedAt),
            let initial = document["initialCapabilities"] as? [String],
            HostAgentXPCWireSnapshotContract.validCapabilities(
                initial,
                requiresClipboardPair: true
            ),
            let active = document["activeCapabilities"] as? [String],
            HostAgentXPCWireSnapshotContract.validCapabilities(
                active,
                requiresClipboardPair: true
            ),
            Set(active).isSubset(of: Set(initial)),
            let availabilityValue = document["inputAvailability"] as? String,
            let availability = HostSessionInputAvailability(
                rawValue: availabilityValue
            ),
            let reason = Self.decodeReason(
                document["inputUnavailableReason"]
            ),
            Self.validAvailability(
                availability,
                reason: reason,
                controlsInput: active.contains("controlKeyboardMouse")
            )
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        self.connectionID = connectionID
        self.remoteID = remoteID
        self.remoteName = remoteName
        self.remotePlatform = remotePlatform
        self.startedAt = startedAt
        initialCapabilities = initial
        activeCapabilities = active
        inputAvailability = availability
        inputUnavailableReason = reason
    }

    fileprivate var document: [String: Any] {
        [
            "connectionId": connectionID,
            "remoteId": remoteID,
            "remoteName": remoteName,
            "remotePlatform": remotePlatform,
            "remoteMetadataTrust": "untrusted",
            "startedAt": startedAt,
            "initialCapabilities": initialCapabilities,
            "activeCapabilities": activeCapabilities,
            "inputAvailability": inputAvailability.rawValue,
            "inputUnavailableReason": inputUnavailableReason?.rawValue
                ?? NSNull(),
        ]
    }

    private static func decodeReason(
        _ value: Any?
    ) -> HostSessionInputUnavailableReason?? {
        if value is NSNull { return .some(nil) }
        guard let text = value as? String,
              let reason = HostSessionInputUnavailableReason(rawValue: text)
        else { return nil }
        return .some(reason)
    }

    private static func validAvailability(
        _ availability: HostSessionInputAvailability,
        reason: HostSessionInputUnavailableReason?,
        controlsInput: Bool
    ) -> Bool {
        switch (availability, reason, controlsInput) {
        case (.available, nil, true):
            return true
        case (.disabled, .localPolicyDisabled, false),
             (.disabled, .remoteDisabled, false),
             (.limited, .accessibilityDenied, false),
             (.limited, .sessionUnavailable, false):
            return true
        default:
            return false
        }
    }
}

package struct HostAgentXPCWirePasswordPolicy: Equatable, Sendable {
    package let localPasswordSet: Bool
    package let effectivePasswordSet: Bool
    package let usingPresetPassword: Bool
    package let changeAllowed: Bool
    package let strengthPolicyVersion: Int
    package let minimumCharacters: Int
    package let maximumCharacters: Int
    package let maximumUTF8Bytes: Int
    package let rejectsControlCharacters: Bool
    package let rejectsOuterWhitespace: Bool

    fileprivate init(_ value: HostPermanentPasswordPolicy) throws {
        try self.init(
            localPasswordSet: value.localPasswordSet,
            effectivePasswordSet: value.effectivePasswordSet,
            usingPresetPassword: value.usingPresetPassword,
            changeAllowed: value.changeAllowed,
            strengthPolicyVersion: value.strengthPolicyVersion,
            minimumCharacters: value.minimumCharacters,
            maximumCharacters: value.maximumCharacters,
            maximumUTF8Bytes: value.maximumUTF8Bytes,
            rejectsControlCharacters: value.rejectsControlCharacters,
            rejectsOuterWhitespace: value.rejectsOuterWhitespace
        )
    }

    fileprivate init(document: [String: Any]) throws {
        guard Set(document.keys) == Set([
            "localPasswordSet", "effectivePasswordSet", "usingPresetPassword",
            "changeAllowed", "strengthPolicyVersion", "minimumCharacters",
            "maximumCharacters", "maximumUtf8Bytes",
            "rejectsControlCharacters", "rejectsOuterWhitespace",
        ]),
            let localPasswordSet = HostAgentXPCWireSnapshotContract.strictBool(
                document["localPasswordSet"]
            ),
            let effectivePasswordSet =
                HostAgentXPCWireSnapshotContract.strictBool(
                    document["effectivePasswordSet"]
                ),
            let usingPresetPassword =
                HostAgentXPCWireSnapshotContract.strictBool(
                    document["usingPresetPassword"]
                ),
            let changeAllowed = HostAgentXPCWireSnapshotContract.strictBool(
                document["changeAllowed"]
            ),
            let strengthPolicyVersion = HostAgentXPCWireSnapshotContract.strictInt(
                document["strengthPolicyVersion"]
            ),
            let minimumCharacters = HostAgentXPCWireSnapshotContract.strictInt(
                document["minimumCharacters"]
            ),
            let maximumCharacters = HostAgentXPCWireSnapshotContract.strictInt(
                document["maximumCharacters"]
            ),
            let maximumUTF8Bytes = HostAgentXPCWireSnapshotContract.strictInt(
                document["maximumUtf8Bytes"]
            ),
            let rejectsControlCharacters =
                HostAgentXPCWireSnapshotContract.strictBool(
                    document["rejectsControlCharacters"]
                ),
            let rejectsOuterWhitespace =
                HostAgentXPCWireSnapshotContract.strictBool(
                    document["rejectsOuterWhitespace"]
                )
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        try self.init(
            localPasswordSet: localPasswordSet,
            effectivePasswordSet: effectivePasswordSet,
            usingPresetPassword: usingPresetPassword,
            changeAllowed: changeAllowed,
            strengthPolicyVersion: strengthPolicyVersion,
            minimumCharacters: minimumCharacters,
            maximumCharacters: maximumCharacters,
            maximumUTF8Bytes: maximumUTF8Bytes,
            rejectsControlCharacters: rejectsControlCharacters,
            rejectsOuterWhitespace: rejectsOuterWhitespace
        )
    }

    private init(
        localPasswordSet: Bool,
        effectivePasswordSet: Bool,
        usingPresetPassword: Bool,
        changeAllowed: Bool,
        strengthPolicyVersion: Int,
        minimumCharacters: Int,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int,
        rejectsControlCharacters: Bool,
        rejectsOuterWhitespace: Bool
    ) throws {
        guard (1...Int(UInt32.max)).contains(strengthPolicyVersion),
              (1...4_096).contains(minimumCharacters),
              (minimumCharacters...4_096).contains(maximumCharacters),
              (maximumCharacters...16_384).contains(maximumUTF8Bytes)
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        self.localPasswordSet = localPasswordSet
        self.effectivePasswordSet = effectivePasswordSet
        self.usingPresetPassword = usingPresetPassword
        self.changeAllowed = changeAllowed
        self.strengthPolicyVersion = strengthPolicyVersion
        self.minimumCharacters = minimumCharacters
        self.maximumCharacters = maximumCharacters
        self.maximumUTF8Bytes = maximumUTF8Bytes
        self.rejectsControlCharacters = rejectsControlCharacters
        self.rejectsOuterWhitespace = rejectsOuterWhitespace
    }

    fileprivate var document: [String: Any] {
        [
            "localPasswordSet": localPasswordSet,
            "effectivePasswordSet": effectivePasswordSet,
            "usingPresetPassword": usingPresetPassword,
            "changeAllowed": changeAllowed,
            "strengthPolicyVersion": strengthPolicyVersion,
            "minimumCharacters": minimumCharacters,
            "maximumCharacters": maximumCharacters,
            "maximumUtf8Bytes": maximumUTF8Bytes,
            "rejectsControlCharacters": rejectsControlCharacters,
            "rejectsOuterWhitespace": rejectsOuterWhitespace,
        ]
    }
}

package struct HostAgentXPCWireSnapshotPayload: Equatable, Sendable {
    package let schemaVersion: Int
    package let hostState: String
    package let localID: String
    package let registrationStatus: String
    package let recoveryEpoch: UInt64
    package let recoveryStatus: HostRecoveryStatus
    package let pendingApproval: HostAgentXPCWirePendingApproval?
    package let activeSession: HostAgentXPCWireActiveSession?
    package let temporaryPasswordPolicy: String
    package let passwordPolicy: HostAgentXPCWirePasswordPolicy
    package let lastError: String?
    package let observedAt: UInt64

    fileprivate init(_ projection: HostAgentSnapshotProjection) throws {
        let pendingApproval: HostAgentXPCWirePendingApproval?
        if let pending = projection.pendingApproval {
            let projected = HostAgentXPCWirePendingApproval(pending)
            pendingApproval = try HostAgentXPCWirePendingApproval(
                document: projected.document
            )
        } else {
            pendingApproval = nil
        }
        let activeSession: HostAgentXPCWireActiveSession?
        if let active = projection.activeSession {
            let projected = HostAgentXPCWireActiveSession(active)
            activeSession = try HostAgentXPCWireActiveSession(
                document: projected.document,
                hostInstanceID: projection.hostInstanceID
            )
        } else {
            activeSession = nil
        }
        try self.init(
            schemaVersion: projection.schemaVersion,
            hostState: projection.hostState,
            localID: projection.localID,
            registrationStatus: projection.registrationStatus,
            recoveryEpoch: projection.recoveryEpoch,
            recoveryStatus: projection.recoveryStatus,
            pendingApproval: pendingApproval,
            activeSession: activeSession,
            temporaryPasswordPolicy: projection.temporaryPasswordPolicy,
            passwordPolicy: try HostAgentXPCWirePasswordPolicy(
                projection.passwordPolicy
            ),
            lastError: projection.lastError,
            observedAt: projection.observedAt
        )
    }

    fileprivate init(
        document: [String: Any],
        hostInstanceID: String
    ) throws {
        guard Set(document.keys) == Set([
            "schemaVersion", "hostState", "localId", "registrationStatus",
            "recoveryEpoch", "recoveryStatus",
            "pendingApproval", "activeSession", "temporaryPasswordPolicy",
            "passwordPolicy", "lastError", "observedAt",
        ]),
            let schemaVersion = HostAgentXPCWireSnapshotContract.strictInt(
                document["schemaVersion"]
            ),
            let hostState = document["hostState"] as? String,
            let localID = document["localId"] as? String,
            let registrationStatus = document["registrationStatus"] as? String,
            let recoveryEpoch = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["recoveryEpoch"]
            ),
            let recoveryStatusValue = document["recoveryStatus"] as? String,
            let recoveryStatus = HostRecoveryStatus(rawValue: recoveryStatusValue),
            let temporaryPasswordPolicy =
                document["temporaryPasswordPolicy"] as? String,
            let passwordPolicyDocument =
                document["passwordPolicy"] as? [String: Any],
            let observedAt = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["observedAt"]
            )
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        let pendingApproval: HostAgentXPCWirePendingApproval?
        if document["pendingApproval"] is NSNull {
            pendingApproval = nil
        } else if let pending = document["pendingApproval"] as? [String: Any] {
            pendingApproval = try HostAgentXPCWirePendingApproval(document: pending)
        } else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        let activeSession: HostAgentXPCWireActiveSession?
        if document["activeSession"] is NSNull {
            activeSession = nil
        } else if let active = document["activeSession"] as? [String: Any] {
            activeSession = try HostAgentXPCWireActiveSession(
                document: active,
                hostInstanceID: hostInstanceID
            )
        } else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        guard let lastError = HostAgentXPCWireSnapshotContract.decodeOptionalText(
            document["lastError"],
            maximumUTF8Bytes:
                HostAgentXPCWireSnapshotContract.maximumLastErrorBytes
        ) else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        try self.init(
            schemaVersion: schemaVersion,
            hostState: hostState,
            localID: localID,
            registrationStatus: registrationStatus,
            recoveryEpoch: recoveryEpoch,
            recoveryStatus: recoveryStatus,
            pendingApproval: pendingApproval,
            activeSession: activeSession,
            temporaryPasswordPolicy: temporaryPasswordPolicy,
            passwordPolicy: try HostAgentXPCWirePasswordPolicy(
                document: passwordPolicyDocument
            ),
            lastError: lastError,
            observedAt: observedAt
        )
    }

    private init(
        schemaVersion: Int,
        hostState: String,
        localID: String,
        registrationStatus: String,
        recoveryEpoch: UInt64,
        recoveryStatus: HostRecoveryStatus,
        pendingApproval: HostAgentXPCWirePendingApproval?,
        activeSession: HostAgentXPCWireActiveSession?,
        temporaryPasswordPolicy: String,
        passwordPolicy: HostAgentXPCWirePasswordPolicy,
        lastError: String?,
        observedAt: UInt64
    ) throws {
        let lastErrorIsValid = lastError.map {
            HostAgentXPCWireSnapshotContract.validText(
                $0,
                maximumUTF8Bytes:
                    HostAgentXPCWireSnapshotContract.maximumLastErrorBytes,
                allowEmpty: false
            )
        } ?? true
        let recoveryContractIsValid: Bool
        switch recoveryStatus {
        case .running:
            recoveryContractIsValid = true
        case .suspending:
            recoveryContractIsValid = recoveryEpoch > 0
                && hostState == "starting"
                && registrationStatus == "suspending"
        case .suspended:
            recoveryContractIsValid = recoveryEpoch > 0
                && hostState == "starting"
                && registrationStatus == "suspended"
        case .resuming:
            recoveryContractIsValid = recoveryEpoch > 0
                && hostState == "starting"
                && registrationStatus == "pending"
        case .failed:
            recoveryContractIsValid = hostState == "error"
                && registrationStatus == "degraded"
        }
        guard schemaVersion == 6,
              HostAgentXPCWireSnapshotContract.allowedHostStates.contains(
                hostState
              ),
              hostState.utf8.count
                <= HostAgentXPCWireSnapshotContract.maximumStatusBytes,
              HostAgentXPCWireSnapshotContract.validText(
                localID,
                maximumUTF8Bytes:
                    HostAgentXPCWireSnapshotContract.maximumLocalIDBytes,
                allowEmpty: true
              ),
              HostAgentXPCWireSnapshotContract.allowedRegistrationStatuses
                .contains(registrationStatus),
              temporaryPasswordPolicy == "redacted",
              recoveryContractIsValid,
              lastErrorIsValid,
              HostAgentXPCWireSnapshotContract.validTimestamp(observedAt)
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        self.schemaVersion = schemaVersion
        self.hostState = hostState
        self.localID = localID
        self.registrationStatus = registrationStatus
        self.recoveryEpoch = recoveryEpoch
        self.recoveryStatus = recoveryStatus
        self.pendingApproval = pendingApproval
        self.activeSession = activeSession
        self.temporaryPasswordPolicy = temporaryPasswordPolicy
        self.passwordPolicy = passwordPolicy
        self.lastError = lastError
        self.observedAt = observedAt
    }

    fileprivate var document: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "hostState": hostState,
            "localId": localID,
            "registrationStatus": registrationStatus,
            "recoveryEpoch": recoveryEpoch,
            "recoveryStatus": recoveryStatus.rawValue,
            "pendingApproval": pendingApproval?.document ?? NSNull(),
            "activeSession": activeSession?.document ?? NSNull(),
            "temporaryPasswordPolicy": temporaryPasswordPolicy,
            "passwordPolicy": passwordPolicy.document,
            "lastError": lastError ?? NSNull(),
            "observedAt": observedAt,
        ]
    }
}

package struct HostAgentXPCWireSnapshotResponse: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let wireVersion: UInt64
    package let requestID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64
    package let payloadLength: UInt64
    /// Agent-local arrival-order cursor, scoped to `agentBootID`.
    package let lastEventID: UInt64
    package let snapshot: HostAgentXPCWireSnapshotPayload

    private init(
        requestID: String,
        wireVersion: UInt64,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64,
        lastEventID: UInt64,
        snapshot: HostAgentXPCWireSnapshotPayload,
        declaredPayloadLength: UInt64? = nil
    ) throws {
        guard wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              HostAgentXPCWireSnapshotContract.validTimestamp(
                sentAtUnixMilliseconds
              ),
              lastEventID
                <= HostAgentXPCWireSnapshotContract.maximumExactJSONInteger
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        let payload = Self.payloadDocument(
            lastEventID: lastEventID,
            snapshot: snapshot
        )
        let payloadLength = UInt64(
            try HostAgentXPCWireSnapshotContract.encodePayload(payload).count
        )
        guard declaredPayloadLength == nil
                || declaredPayloadLength == payloadLength
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        schemaVersion = HostAgentXPCWireSnapshotContract.currentSchemaVersion
        self.wireVersion = wireVersion
        self.requestID = requestID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
        self.payloadLength = payloadLength
        self.lastEventID = lastEventID
        self.snapshot = snapshot
    }

    package static func make(
        for request: HostAgentXPCWireSnapshotRequest,
        identity: HostAgentXPCWireAgentIdentity,
        state: HostAgentSnapshotStateView,
        sentAtUnixMilliseconds: UInt64
    ) throws -> Self {
        guard request.wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID,
              state.status == .available,
              state.hostInstanceID == identity.hostInstanceID,
              let projection = state.projection,
              projection.hostInstanceID == identity.hostInstanceID
        else {
            throw HostAgentXPCWireSnapshotDocumentError.snapshotUnavailable
        }
        return try Self(
            requestID: request.requestID,
            wireVersion: request.wireVersion,
            hostInstanceID: identity.hostInstanceID,
            agentBootID: identity.agentBootID,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds,
            lastEventID: state.eventSequence,
            snapshot: try HostAgentXPCWireSnapshotPayload(projection)
        )
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireSnapshotContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "wireVersion", "messageType", "requestId",
            "hostInstanceId", "agentBootId", "sentAtUnixMilliseconds",
            "payloadLength", "payload",
        ]),
            document["messageType"] as? String == "snapshotResponse",
            let wireVersion = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["wireVersion"]
            ),
            let requestID = document["requestId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAt = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["sentAtUnixMilliseconds"]
            ),
            let payloadLength = HostAgentXPCWireSnapshotContract.strictUInt64(
                document["payloadLength"]
            ),
            let payload = document["payload"] as? [String: Any],
            Set(payload.keys) == Set(["lastEventId", "snapshot"]),
            let lastEventID = HostAgentXPCWireSnapshotContract.strictUInt64(
                payload["lastEventId"]
            ),
            let snapshotDocument = payload["snapshot"] as? [String: Any]
        else {
            throw HostAgentXPCWireSnapshotDocumentError.invalidDocument
        }
        try HostAgentXPCWireSnapshotContract.decodeSchemaVersion(document)
        return try Self(
            requestID: requestID,
            wireVersion: wireVersion,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAt,
            lastEventID: lastEventID,
            snapshot: try HostAgentXPCWireSnapshotPayload(
                document: snapshotDocument,
                hostInstanceID: hostInstanceID
            ),
            declaredPayloadLength: payloadLength
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireSnapshotContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "wireVersion": wireVersion,
            "messageType": "snapshotResponse",
            "requestId": requestID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
            "payloadLength": payloadLength,
            "payload": Self.payloadDocument(
                lastEventID: lastEventID,
                snapshot: snapshot
            ),
        ])
    }

    package func evaluate(
        for request: HostAgentXPCWireSnapshotRequest
    ) -> HostAgentXPCWireSnapshotEvaluation {
        guard requestID == request.requestID,
              wireVersion == request.wireVersion,
              hostInstanceID == request.hostInstanceID,
              agentBootID == request.agentBootID
        else { return .invalidResponse }
        return .correlated
    }

    private static func payloadDocument(
        lastEventID: UInt64,
        snapshot: HostAgentXPCWireSnapshotPayload
    ) -> [String: Any] {
        [
            "lastEventId": lastEventID,
            "snapshot": snapshot.document,
        ]
    }
}
