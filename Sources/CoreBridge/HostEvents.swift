import CoreBridgeShim
import Foundation

public struct HostPermanentPasswordPolicy: Sendable {
    public let localPasswordSet: Bool
    public let effectivePasswordSet: Bool
    public let usingPresetPassword: Bool
    public let changeAllowed: Bool
    public let strengthPolicyVersion: Int
    public let minimumCharacters: Int
    public let maximumCharacters: Int
    public let maximumUTF8Bytes: Int
    public let rejectsControlCharacters: Bool
    public let rejectsOuterWhitespace: Bool

    package init(
        localPasswordSet: Bool, effectivePasswordSet: Bool, usingPresetPassword: Bool,
        changeAllowed: Bool, strengthPolicyVersion: Int, minimumCharacters: Int,
        maximumCharacters: Int, maximumUTF8Bytes: Int, rejectsControlCharacters: Bool,
        rejectsOuterWhitespace: Bool
    ) {
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
}

/// Versioned event envelope delivered on the host event channel (§8.5).
public struct HostCoreEvent: Sendable {
    public let schemaVersion: Int
    public let eventId: UInt64
    public let eventType: String
    public let hostInstanceId: String
    public let sentAt: UInt64
    public let rawJSON: Data

    /// Decodes the versioned event envelope copied from the Host Control ABI.
    /// Unknown schema versions and incomplete envelopes fail closed.
    public init?(rawJSON: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: rawJSON),
            let envelope = object as? [String: Any],
            let schemaVersion = (envelope["schemaVersion"] as? NSNumber)?.intValue,
            schemaVersion == 1, let eventID = (envelope["eventId"] as? NSNumber)?.uint64Value,
            let eventType = envelope["eventType"] as? String, !eventType.isEmpty,
            let hostInstanceID = envelope["hostInstanceId"] as? String, !hostInstanceID.isEmpty,
            let sentAt = (envelope["sentAt"] as? NSNumber)?.uint64Value, sentAt > 0
        else { return nil }
        self.schemaVersion = schemaVersion
        self.eventId = eventID
        self.eventType = eventType
        self.hostInstanceId = hostInstanceID
        self.sentAt = sentAt
        self.rawJSON = rawJSON
    }
}
