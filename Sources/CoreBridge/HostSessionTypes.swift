import CoreBridgeShim
import Foundation

public enum HostSessionAvailability: String, Equatable, Sendable {
    case available
    case limited
}

public enum HostSessionUnavailableReason: String, Equatable, Sendable { case sessionUnavailable }

public enum HostSessionInputAvailability: String, Equatable, Sendable {
    case available
    case disabled
    case limited
}

public enum HostSessionInputUnavailableReason: String, Equatable, Sendable {
    case localPolicyDisabled
    case remoteDisabled
    case accessibilityDenied
    case sessionUnavailable
}

public struct HostActiveSession: Equatable, Sendable {
    public let connectionId: String
    public let remoteId: String
    public let remoteName: String
    public let remotePlatform: String
    public let startedAt: UInt64
    public let initialCapabilities: [String]
    public let activeCapabilities: [String]
    public let inputAvailability: HostSessionInputAvailability
    public let inputUnavailableReason: HostSessionInputUnavailableReason?

    init?(json: [String: Any], hostInstanceID: String) {
        let expectedKeys = Set([
            "connectionId", "remoteId", "remoteName", "remotePlatform", "remoteMetadataTrust",
            "startedAt", "initialCapabilities", "activeCapabilities", "inputAvailability",
            "inputUnavailableReason",
        ])
        let allowedCapabilities = Set([
            "viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard",
            "hearSystemAudio",
        ])
        guard Set(json.keys) == expectedKeys, let connectionID = json["connectionId"] as? String,
            Self.valid(connectionID, maximumUTF8Bytes: 128, allowEmpty: false),
            connectionID.hasPrefix("\(hostInstanceID):"),
            let remoteID = json["remoteId"] as? String,
            Self.valid(remoteID, maximumUTF8Bytes: 256, allowEmpty: false),
            let remoteName = json["remoteName"] as? String,
            Self.valid(remoteName, maximumUTF8Bytes: 256, allowEmpty: true),
            let remotePlatform = json["remotePlatform"] as? String,
            Self.valid(remotePlatform, maximumUTF8Bytes: 256, allowEmpty: true),
            json["remoteMetadataTrust"] as? String == "untrusted",
            let startedAt = (json["startedAt"] as? NSNumber)?.uint64Value, startedAt > 0,
            let initialCapabilities = json["initialCapabilities"] as? [String],
            let activeCapabilities = json["activeCapabilities"] as? [String],
            let inputAvailabilityValue = json["inputAvailability"] as? String,
            let inputAvailability = HostSessionInputAvailability(rawValue: inputAvailabilityValue),
            let inputUnavailableReasonValue = json["inputUnavailableReason"],
            Self.validCapabilities(initialCapabilities, allowed: allowedCapabilities),
            Self.validCapabilities(activeCapabilities, allowed: allowedCapabilities),
            Set(activeCapabilities).isSubset(of: Set(initialCapabilities)),
            let inputUnavailableReason = Self.inputUnavailableReason(
                from: inputUnavailableReasonValue),
            Self.validInputAvailability(
                inputAvailability, reason: inputUnavailableReason,
                controlsKeyboardAndMouse: activeCapabilities.contains("controlKeyboardMouse"))
        else { return nil }

        connectionId = connectionID
        remoteId = remoteID
        self.remoteName = remoteName
        self.remotePlatform = remotePlatform
        self.startedAt = startedAt
        self.initialCapabilities = initialCapabilities
        self.activeCapabilities = activeCapabilities
        self.inputAvailability = inputAvailability
        self.inputUnavailableReason = inputUnavailableReason
    }

    private static func inputUnavailableReason(from value: Any)
        -> HostSessionInputUnavailableReason??
    {
        if value is NSNull { return .some(nil) }
        guard let rawValue = value as? String,
            let reason = HostSessionInputUnavailableReason(rawValue: rawValue)
        else { return nil }
        return .some(reason)
    }

    private static func validInputAvailability(
        _ availability: HostSessionInputAvailability, reason: HostSessionInputUnavailableReason?,
        controlsKeyboardAndMouse: Bool
    ) -> Bool {
        switch (availability, reason, controlsKeyboardAndMouse) {
        case (.available, nil, true): return true
        case (.disabled, .localPolicyDisabled, false), (.disabled, .remoteDisabled, false),
            (.limited, .accessibilityDenied, false), (.limited, .sessionUnavailable, false):
            return true
        default: return false
        }
    }

    private static func validCapabilities(_ capabilities: [String], allowed: Set<String>) -> Bool {
        let capabilitySet = Set(capabilities)
        return (1...16).contains(capabilities.count) && capabilitySet.count == capabilities.count
            && capabilitySet.contains("viewDisplay") && capabilitySet.isSubset(of: allowed)
    }

    private static func valid(_ value: String, maximumUTF8Bytes: Int, allowEmpty: Bool) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= maximumUTF8Bytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct HostPendingApproval: Equatable, Sendable {
    public let connectionId: String
    public let remoteId: String
    public let remoteName: String
    public let remotePlatform: String
    public let requestedAt: UInt64
    public let expiresAt: UInt64
    public let requestedCapabilities: [String]
    public let transport: String
    public let authenticationMethod: String
    public let riskAlerts: [String]

    init?(json: [String: Any]) {
        let expectedKeys = Set([
            "connectionId", "remoteId", "remoteName", "remotePlatform", "remoteMetadataTrust",
            "requestedAt", "expiresAt", "requestedCapabilities", "transport",
            "authenticationMethod", "riskAlerts",
        ])
        let allowedCapabilities = Set([
            "viewDisplay", "controlKeyboardMouse", "readClipboard", "writeClipboard",
            "hearSystemAudio",
        ])
        guard Set(json.keys) == expectedKeys, let connectionID = json["connectionId"] as? String,
            Self.valid(connectionID, maximumUTF8Bytes: 128, allowEmpty: false),
            let remoteID = json["remoteId"] as? String,
            Self.valid(remoteID, maximumUTF8Bytes: 256, allowEmpty: false),
            let remoteName = json["remoteName"] as? String,
            Self.valid(remoteName, maximumUTF8Bytes: 256, allowEmpty: true),
            let remotePlatform = json["remotePlatform"] as? String,
            Self.valid(remotePlatform, maximumUTF8Bytes: 256, allowEmpty: true),
            json["remoteMetadataTrust"] as? String == "untrusted",
            let requestedAt = (json["requestedAt"] as? NSNumber)?.uint64Value, requestedAt > 0,
            let expiresAt = (json["expiresAt"] as? NSNumber)?.uint64Value, expiresAt > requestedAt,
            let requestedCapabilities = json["requestedCapabilities"] as? [String],
            (1...16).contains(requestedCapabilities.count),
            requestedCapabilities.contains("viewDisplay"),
            Set(requestedCapabilities).count == requestedCapabilities.count,
            requestedCapabilities.allSatisfy(allowedCapabilities.contains),
            let transport = json["transport"] as? String,
            ["direct", "relay", "unknown"].contains(transport),
            let authenticationMethod = json["authenticationMethod"] as? String,
            authenticationMethod == "localApproval",
            let riskAlerts = json["riskAlerts"] as? [String], riskAlerts.isEmpty
        else { return nil }

        connectionId = connectionID
        remoteId = remoteID
        self.remoteName = remoteName
        self.remotePlatform = remotePlatform
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.requestedCapabilities = requestedCapabilities
        self.transport = transport
        self.authenticationMethod = authenticationMethod
        self.riskAlerts = riskAlerts
    }

    private static func valid(_ value: String, maximumUTF8Bytes: Int, allowEmpty: Bool) -> Bool {
        (allowEmpty || !value.isEmpty) && value.utf8.count <= maximumUTF8Bytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Keeps UI decisions bound to the exact pending request recovered from the
/// latest Host snapshot. It does not authorize anything itself; Rust remains
/// authoritative for request identity, deadline and final state.
