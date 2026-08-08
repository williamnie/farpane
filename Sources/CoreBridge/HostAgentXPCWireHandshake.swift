import CoreFoundation
import Foundation

package enum HostAgentXPCWireHandshakeDocumentError: Error, Equatable {
    case invalidDocument
    case documentTooLarge
    case unsupportedSchema(UInt64)
}

package enum HostAgentXPCWireHandshakeCompatibility: String, Sendable {
    case compatible
    case incompatible
}

package enum HostAgentXPCWireHandshakeEvaluation: Equatable, Sendable {
    case compatible(selectedWireVersion: UInt64)
    case incompatible
    case invalidResponse
}

package struct HostAgentXPCWireAgentIdentity: Equatable, Sendable {
    package let agentBuildID: String
    package let hostInstanceID: String
    package let agentBootID: String

    package init(
        agentBuildID: String,
        hostInstanceID: String,
        agentBootID: String
    ) throws {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
            agentBuildID
        ),
            HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
            HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID)
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        self.agentBuildID = agentBuildID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
    }
}

package enum HostAgentXPCWireHandshakeContract {
    package static let currentSchemaVersion: UInt64 = 1
    package static let currentWireVersion: UInt64 = 1
    package static let supportedWireVersions: [UInt64] = [currentWireVersion]
    package static let maximumDocumentBytes = 8 * 1_024
    package static let maximumSupportedVersionCount = 8

    fileprivate static let maximumExactJSONInteger: UInt64 =
        9_007_199_254_740_991
    fileprivate static let maximumIdentifierBytes = 128
    fileprivate static let identifierPunctuation = ".-_+".unicodeScalars

    fileprivate static func decodeDocument(_ data: Data) throws
        -> [String: Any]
    {
        guard !data.isEmpty else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireHandshakeDocumentError.documentTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        guard let document = value as? [String: Any] else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
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
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        guard data.count <= maximumDocumentBytes else {
            throw HostAgentXPCWireHandshakeDocumentError.documentTooLarge
        }
        return data
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

    fileprivate static func decodeSchemaVersion(
        _ document: [String: Any]
    ) throws -> UInt64 {
        guard let schemaVersion = strictUInt64(document["schemaVersion"])
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        guard schemaVersion == currentSchemaVersion else {
            throw HostAgentXPCWireHandshakeDocumentError.unsupportedSchema(
                schemaVersion
            )
        }
        return schemaVersion
    }

    fileprivate static func validVersions(_ versions: [UInt64]) -> Bool {
        guard !versions.isEmpty,
              versions.count <= maximumSupportedVersionCount
        else { return false }
        var previous: UInt64 = 0
        for version in versions {
            guard version > previous, version <= UInt64(UInt32.max) else {
                return false
            }
            previous = version
        }
        return true
    }

    fileprivate static func decodeVersions(_ value: Any?) -> [UInt64]? {
        guard let rawVersions = value as? [Any] else { return nil }
        let versions = rawVersions.compactMap(strictUInt64)
        guard versions.count == rawVersions.count,
              validVersions(versions)
        else { return nil }
        return versions
    }

    fileprivate static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumIdentifierBytes
        else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
                || identifierPunctuation.contains($0)
        }
    }

    fileprivate static func validCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value)
        else { return false }
        return uuid.uuidString.lowercased() == value
    }

    fileprivate static func decodeOptionalIdentifier(_ value: Any?) throws
        -> String?
    {
        if value is NSNull { return nil }
        guard let value = value as? String, validIdentifier(value) else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        return value
    }

    fileprivate static func decodeOptionalUUID(_ value: Any?) throws -> String? {
        if value is NSNull { return nil }
        guard let value = value as? String, validCanonicalUUID(value) else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        return value
    }
}

package struct HostAgentXPCWireHandshakeRequest: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let requestID: String
    package let supportedWireVersions: [UInt64]
    package let appBuildID: String
    package let knownHostInstanceID: String?
    package let knownAgentBootID: String?
    package let sentAtUnixMilliseconds: UInt64

    package init(
        requestID: String,
        supportedWireVersions: [UInt64],
        appBuildID: String,
        knownHostInstanceID: String?,
        knownAgentBootID: String?,
        sentAtUnixMilliseconds: UInt64
    ) throws {
        if let knownHostInstanceID,
           !HostAgentXPCWireHandshakeContract.validIdentifier(
               knownHostInstanceID
           )
        {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        if let knownAgentBootID,
           !HostAgentXPCWireHandshakeContract.validCanonicalUUID(
               knownAgentBootID
           )
        {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        guard HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validVersions(
                  supportedWireVersions
              ),
              HostAgentRegistrationBundlePreflight.validBuildIdentifier(
                  appBuildID
              ),
              sentAtUnixMilliseconds > 0,
              sentAtUnixMilliseconds
                <= HostAgentXPCWireHandshakeContract.maximumExactJSONInteger
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        schemaVersion = HostAgentXPCWireHandshakeContract.currentSchemaVersion
        self.requestID = requestID
        self.supportedWireVersions = supportedWireVersions
        self.appBuildID = appBuildID
        self.knownHostInstanceID = knownHostInstanceID
        self.knownAgentBootID = knownAgentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
    }

    package static func makeProductRequest(
        requestID: String,
        appBuildID: String,
        knownHostInstanceID: String?,
        knownAgentBootID: String?,
        sentAtUnixMilliseconds: UInt64
    ) throws -> Self {
        try Self(
            requestID: requestID,
            supportedWireVersions:
                HostAgentXPCWireHandshakeContract.supportedWireVersions,
            appBuildID: appBuildID,
            knownHostInstanceID: knownHostInstanceID,
            knownAgentBootID: knownAgentBootID,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        )
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireHandshakeContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "messageType", "requestId",
            "supportedWireVersions", "appBuildId", "hostInstanceId",
            "agentBootId", "sentAtUnixMilliseconds",
        ]),
            document["messageType"] as? String == "handshakeRequest",
            let requestID = document["requestId"] as? String,
            let supportedWireVersions =
                HostAgentXPCWireHandshakeContract.decodeVersions(
                    document["supportedWireVersions"]
                ),
            let appBuildID = document["appBuildId"] as? String,
            let sentAtUnixMilliseconds =
                HostAgentXPCWireHandshakeContract.strictUInt64(
                    document["sentAtUnixMilliseconds"]
                )
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        _ = try HostAgentXPCWireHandshakeContract.decodeSchemaVersion(document)
        return try Self(
            requestID: requestID,
            supportedWireVersions: supportedWireVersions,
            appBuildID: appBuildID,
            knownHostInstanceID: try HostAgentXPCWireHandshakeContract
                .decodeOptionalIdentifier(document["hostInstanceId"]),
            knownAgentBootID: try HostAgentXPCWireHandshakeContract
                .decodeOptionalUUID(document["agentBootId"]),
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireHandshakeContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "messageType": "handshakeRequest",
            "requestId": requestID,
            "supportedWireVersions": supportedWireVersions,
            "appBuildId": appBuildID,
            "hostInstanceId": knownHostInstanceID ?? NSNull(),
            "agentBootId": knownAgentBootID ?? NSNull(),
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
        ])
    }
}

package struct HostAgentXPCWireHandshakeResponse: Equatable, Sendable {
    package let schemaVersion: UInt64
    package let requestID: String
    package let supportedWireVersions: [UInt64]
    package let selectedWireVersion: UInt64?
    package let compatibility: HostAgentXPCWireHandshakeCompatibility
    package let agentBuildID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let sentAtUnixMilliseconds: UInt64

    fileprivate init(
        requestID: String,
        supportedWireVersions: [UInt64],
        selectedWireVersion: UInt64?,
        compatibility: HostAgentXPCWireHandshakeCompatibility,
        agentBuildID: String,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64
    ) throws {
        guard HostAgentXPCWireHandshakeContract.validCanonicalUUID(requestID),
              HostAgentXPCWireHandshakeContract.validVersions(
                  supportedWireVersions
              ),
              HostAgentRegistrationBundlePreflight.validBuildIdentifier(
                  agentBuildID
              ),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
              sentAtUnixMilliseconds > 0,
              sentAtUnixMilliseconds
                <= HostAgentXPCWireHandshakeContract.maximumExactJSONInteger
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        switch compatibility {
        case .compatible:
            guard let selectedWireVersion,
                  supportedWireVersions.contains(selectedWireVersion)
            else {
                throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
            }
        case .incompatible:
            guard selectedWireVersion == nil else {
                throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
            }
        }

        schemaVersion = HostAgentXPCWireHandshakeContract.currentSchemaVersion
        self.requestID = requestID
        self.supportedWireVersions = supportedWireVersions
        self.selectedWireVersion = selectedWireVersion
        self.compatibility = compatibility
        self.agentBuildID = agentBuildID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.sentAtUnixMilliseconds = sentAtUnixMilliseconds
    }

    package static func decode(_ data: Data) throws -> Self {
        let document = try HostAgentXPCWireHandshakeContract.decodeDocument(data)
        guard Set(document.keys) == Set([
            "schemaVersion", "messageType", "requestId",
            "supportedWireVersions", "selectedWireVersion", "compatibility",
            "agentBuildId", "hostInstanceId", "agentBootId",
            "sentAtUnixMilliseconds",
        ]),
            document["messageType"] as? String == "handshakeResponse",
            let requestID = document["requestId"] as? String,
            let supportedWireVersions =
                HostAgentXPCWireHandshakeContract.decodeVersions(
                    document["supportedWireVersions"]
                ),
            let compatibilityValue = document["compatibility"] as? String,
            let compatibility = HostAgentXPCWireHandshakeCompatibility(
                rawValue: compatibilityValue
            ),
            let agentBuildID = document["agentBuildId"] as? String,
            let hostInstanceID = document["hostInstanceId"] as? String,
            let agentBootID = document["agentBootId"] as? String,
            let sentAtUnixMilliseconds =
                HostAgentXPCWireHandshakeContract.strictUInt64(
                    document["sentAtUnixMilliseconds"]
                )
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        _ = try HostAgentXPCWireHandshakeContract.decodeSchemaVersion(document)

        let selectedWireVersion: UInt64?
        if document["selectedWireVersion"] is NSNull {
            selectedWireVersion = nil
        } else {
            guard let value = HostAgentXPCWireHandshakeContract.strictUInt64(
                document["selectedWireVersion"]
            ) else {
                throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
            }
            selectedWireVersion = value
        }
        return try Self(
            requestID: requestID,
            supportedWireVersions: supportedWireVersions,
            selectedWireVersion: selectedWireVersion,
            compatibility: compatibility,
            agentBuildID: agentBuildID,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        )
    }

    package func encoded() throws -> Data {
        try HostAgentXPCWireHandshakeContract.encodeDocument([
            "schemaVersion": schemaVersion,
            "messageType": "handshakeResponse",
            "requestId": requestID,
            "supportedWireVersions": supportedWireVersions,
            "selectedWireVersion": selectedWireVersion ?? NSNull(),
            "compatibility": compatibility.rawValue,
            "agentBuildId": agentBuildID,
            "hostInstanceId": hostInstanceID,
            "agentBootId": agentBootID,
            "sentAtUnixMilliseconds": sentAtUnixMilliseconds,
        ])
    }
}

package enum HostAgentXPCWireHandshakeNegotiator {
    package static func makeResponse(
        for request: HostAgentXPCWireHandshakeRequest,
        agentBuildID: String,
        hostInstanceID: String,
        agentBootID: String,
        sentAtUnixMilliseconds: UInt64
    ) throws -> HostAgentXPCWireHandshakeResponse {
        let agentSupportedWireVersions =
            HostAgentXPCWireHandshakeContract.supportedWireVersions
        let selectedWireVersion = highestCommonVersion(
            request.supportedWireVersions,
            agentSupportedWireVersions
        )
        return try HostAgentXPCWireHandshakeResponse(
            requestID: request.requestID,
            supportedWireVersions: agentSupportedWireVersions,
            selectedWireVersion: selectedWireVersion,
            compatibility: selectedWireVersion == nil
                ? .incompatible : .compatible,
            agentBuildID: agentBuildID,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        )
    }

    package static func evaluate(
        _ response: HostAgentXPCWireHandshakeResponse,
        for request: HostAgentXPCWireHandshakeRequest
    ) -> HostAgentXPCWireHandshakeEvaluation {
        guard response.requestID == request.requestID else {
            return .invalidResponse
        }
        let expectedVersion = highestCommonVersion(
            request.supportedWireVersions,
            response.supportedWireVersions
        )
        switch response.compatibility {
        case .compatible:
            guard let selectedWireVersion = response.selectedWireVersion,
                  selectedWireVersion == expectedVersion
            else { return .invalidResponse }
            return .compatible(selectedWireVersion: selectedWireVersion)
        case .incompatible:
            guard response.selectedWireVersion == nil,
                  expectedVersion == nil
            else { return .invalidResponse }
            return .incompatible
        }
    }

    private static func highestCommonVersion(
        _ lhs: [UInt64],
        _ rhs: [UInt64]
    ) -> UInt64? {
        let available = Set(rhs)
        return lhs.reversed().first { available.contains($0) }
    }
}
