import CoreBridgeShim
import Foundation

package enum HostMediaSubmissionDropReason: Equatable, Sendable {
    case networkBackpressure
    case reconfigure
    case invalidFrame
    case shutdown
}

/// Contract errors for the Host Control ABI (§8.1). Codes mirror the stable
/// `RDN_HOST_ERR_*` values so callers can distinguish fail-closed states.
public enum HostControlError: Error, CustomStringConvertible {
    case load(String)
    case hostSurfaceUnavailable
    case abiMismatch(found: UInt32)
    case mediaABIMismatch(found: UInt32)
    case invalidUpstreamCommit(String)
    case configRoot(Int32)
    case create(Int32)
    case start(Int32)
    case command(Int32)
    case permanentPassword(Int32)
    case invalidCommandEnvelope
    case sensitiveCommandRequiresDedicatedABI
    case snapshot(Int32)
    case snapshotDecode(String)
    case stop(Int32)
    case media(Int32)

    public var description: String {
        switch self {
        case .load(let message): return "Host core load failed: \(message)"
        case .hostSurfaceUnavailable: return "core library has no host ABI surface"
        case .abiMismatch(let found): return "host ABI version mismatch: \(found)"
        case .mediaABIMismatch(let found): return "host media ABI version mismatch: \(found)"
        case .invalidUpstreamCommit(let commit): return "unexpected RustDesk core commit: \(commit)"
        case .configRoot(let code): return "config-root switch rejected: \(code)"
        case .create(let code): return "host create failed: \(code)"
        case .start(let code): return "host start failed: \(code)"
        case .command(let code): return "host command rejected: \(code)"
        case .permanentPassword(let code): return "permanent password rejected: \(code)"
        case .invalidCommandEnvelope: return "host command envelope is invalid"
        case .sensitiveCommandRequiresDedicatedABI:
            return "sensitive host command requires the dedicated secret-buffer ABI"
        case .snapshot(let code): return "host snapshot copy failed: \(code)"
        case .snapshotDecode(let message): return "host snapshot decode failed: \(message)"
        case .stop(let code): return "host stop failed: \(code)"
        case .media(let code): return "host media operation rejected: \(code)"
        }
    }

    public var isExpectedMediaDrop: Bool {
        guard case .media(let code) = self else { return false }
        return code == Int32(RDN_HOST_ERR_BACKPRESSURE)
            || code == Int32(RDN_HOST_ERR_STALE_EPOCH)
            || code == Int32(RDN_HOST_ERR_BAD_STATE)
    }

    /// A packet rejected by the bounded encoded queue may be referenced by
    /// later VideoToolbox output. Arm a fresh IDR to bound that missing chain;
    /// stale routes and shutdowns must not affect a new route.
    public var requiresMediaKeyframeRecovery: Bool {
        guard case .media(let code) = self else { return false }
        return code == Int32(RDN_HOST_ERR_BACKPRESSURE)
    }

    public var permanentPasswordFailure: HostPermanentPasswordFailure? {
        guard case .permanentPassword(let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_SECRET_EMPTY): return .empty
        case Int32(RDN_HOST_ERR_SECRET_TOO_SHORT): return .tooShort
        case Int32(RDN_HOST_ERR_SECRET_TOO_LONG): return .tooLong
        case Int32(RDN_HOST_ERR_SECRET_OUTER_WHITESPACE): return .outerWhitespace
        case Int32(RDN_HOST_ERR_SECRET_INVALID_UTF8): return .invalidUTF8
        case Int32(RDN_HOST_ERR_SECRET_FORBIDDEN_CHARACTER): return .forbiddenCharacter
        case Int32(RDN_HOST_ERR_CHANGE_DISABLED): return .changeDisabled
        case Int32(RDN_HOST_ERR_STORAGE): return .storage
        default: return .unknown
        }
    }

    public var approvalDecisionFailure: HostApprovalDecisionFailure? {
        guard case .command(let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_APPROVAL_NOT_FOUND): return .notFound
        case Int32(RDN_HOST_ERR_APPROVAL_FINALIZED): return .alreadyFinalized
        case Int32(RDN_HOST_ERR_APPROVAL_EXPIRED): return .expired
        default: return nil
        }
    }

    public var sessionCommandFailure: HostSessionCommandFailure? {
        guard case .command(let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_SESSION_NOT_FOUND): return .notFound
        case Int32(RDN_HOST_ERR_SESSION_STALE): return .staleConnection
        case Int32(RDN_HOST_ERR_SESSION_COMMAND_UNAVAILABLE): return .unavailable
        default: return nil
        }
    }

    /// Classifies only stable Host Media submit rejections whose production
    /// meaning is known. Internal or future codes stay nil so telemetry cannot
    /// turn an unknown failure into a misleading zero/known drop reason.
    package var mediaSubmissionDropReason: HostMediaSubmissionDropReason? {
        guard case .media(let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_BACKPRESSURE):
            return .networkBackpressure
        case Int32(RDN_HOST_ERR_STALE_EPOCH):
            return .reconfigure
        case Int32(RDN_HOST_ERR_BAD_STATE):
            return .shutdown
        case Int32(RDN_HOST_ERR_INVALID_ARG),
             Int32(RDN_HOST_ERR_ABI_MISMATCH),
             Int32(RDN_HOST_ERR_NOT_SUPPORTED),
             Int32(RDN_HOST_ERR_VALIDATION),
             Int32(RDN_HOST_ERR_PACKET_TOO_LARGE),
             Int32(RDN_HOST_ERR_NON_MONOTONIC_PTS),
             Int32(RDN_HOST_ERR_MISSING_PARAMETER_SETS),
             Int32(RDN_HOST_ERR_CODEC_MISMATCH):
            return .invalidFrame
        default:
            return nil
        }
    }
}

public enum HostPermanentPasswordFailure: Equatable, Sendable {
    case empty
    case tooShort
    case tooLong
    case outerWhitespace
    case invalidUTF8
    case forbiddenCharacter
    case changeDisabled
    case storage
    case unknown
}

public enum HostApprovalDecisionFailure: Equatable, Sendable {
    case notFound
    case alreadyFinalized
    case expired
}

public enum HostApprovalDecision: Equatable, Sendable {
    case approve
    case reject

    fileprivate var commandName: String {
        switch self {
        case .approve: return "approveConnection"
        case .reject: return "rejectConnection"
        }
    }
}

public enum HostSessionCommandFailure: Equatable, Sendable {
    case notFound
    case staleConnection
    case unavailable
}

public enum HostSessionRevocableCapability: Equatable, Sendable {
    case keyboardAndMouse
    case clipboard
    case systemAudio

    package var commandName: String {
        switch self {
        case .keyboardAndMouse: return "disableInputForActiveSession"
        case .clipboard: return "disableClipboardForActiveSession"
        case .systemAudio: return "disableAudioForActiveSession"
        }
    }

    package var snapshotCapabilityNames: Set<String> {
        switch self {
        case .keyboardAndMouse: return ["controlKeyboardMouse"]
        case .clipboard: return ["readClipboard", "writeClipboard"]
        case .systemAudio: return ["hearSystemAudio"]
        }
    }
}

/// Keeps secrets out of the low-frequency JSON command channel (§8.1, §9.3).
///
/// Permanent-password input must eventually use a dedicated mutable byte
/// buffer ABI so both caller and callee can wipe it. JSONSerialization creates
/// immutable/copying storage and is therefore never an acceptable transport
/// for a password, credential, token, private key, or recovery material.
package enum HostCommandEnvelopePolicy {
    private static let reservedKeys = Set(["commandid", "name"])
    private static let sensitiveKeyFragments = [
        "password", "passcode", "credential", "secret", "token",
        "privatekey", "recoverykey",
    ]

    package static func envelope(
        commandName: String,
        commandID: String,
        payload: [String: Any]
    ) throws -> [String: Any] {
        guard !commandName.isEmpty,
              !commandID.isEmpty,
              commandName.utf8.count <= 128,
              commandID.utf8.count <= 128
        else {
            throw HostControlError.invalidCommandEnvelope
        }
        if normalized(commandName) == "setpermanentpassword" {
            throw HostControlError.sensitiveCommandRequiresDedicatedABI
        }
        try validateDictionary(payload, rejectReservedKeys: true)
        var envelope = payload
        envelope["commandId"] = commandID
        envelope["name"] = commandName
        return envelope
    }

    private static func validateDictionary(
        _ dictionary: [String: Any],
        rejectReservedKeys: Bool
    ) throws {
        for (key, value) in dictionary {
            let normalizedKey = normalized(key)
            guard !rejectReservedKeys || !reservedKeys.contains(normalizedKey) else {
                throw HostControlError.invalidCommandEnvelope
            }
            guard !sensitiveKeyFragments.contains(where: normalizedKey.contains) else {
                throw HostControlError.sensitiveCommandRequiresDedicatedABI
            }
            try validateValue(value)
        }
    }

    private static func validateValue(_ value: Any) throws {
        if value is Data || value is NSData {
            throw HostControlError.sensitiveCommandRequiresDedicatedABI
        }
        if let dictionary = value as? [String: Any] {
            try validateDictionary(dictionary, rejectReservedKeys: false)
            return
        }
        if let array = value as? [Any] {
            for element in array { try validateValue(element) }
        }
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}

/// Owns the Swift half of the dedicated secret-buffer contract. The caller's
/// mutable Data is wiped after both success and thrown/error paths; Rust also
/// wipes the same bytes before its C ABI call returns.
package enum HostSecretBufferPolicy {
    package static func withMutableBytes<Result>(
        _ secret: inout Data,
        _ body: (UnsafeMutablePointer<UInt8>?, Int) throws -> Result
    ) rethrows -> Result {
        defer {
            if !secret.isEmpty {
                secret.resetBytes(in: 0..<secret.count)
            }
        }
        return try secret.withUnsafeMutableBytes { rawBuffer in
            let buffer = rawBuffer.bindMemory(to: UInt8.self)
            return try body(buffer.baseAddress, buffer.count)
        }
    }
}

public enum HostStopReason: UInt32, Sendable {
    case userRequest = 0
    case appExit = 1
    case error = 2
}

/// Canonical self-hosted RustDesk server configuration. The public key is
/// hbbs `key.pub`; it authenticates the server and is never an SSH credential.
public struct HostServerConfiguration: Sendable {
    public let rendezvousServer: String
    public let relayServer: String
    public let serverPublicKey: String

    public init(rendezvousServer: String, relayServer: String = "", serverPublicKey: String) {
        self.rendezvousServer = rendezvousServer
        self.relayServer = relayServer
        self.serverPublicKey = serverPublicKey
    }
}

public enum HostMediaCodec: UInt32, Sendable {
    case h264 = 1
    case h265 = 2
}

public enum HostMediaFraming: UInt32, Sendable {
    case annexB = 1
    case avcc = 2
}

public struct HostEncoderCapabilities: Sendable {
    public let h264Hardware: Bool
    public let h265Hardware: Bool
    public let maxWidth: UInt32
    public let maxHeight: UInt32
    public let maxFPS: UInt32

    public init(
        h264Hardware: Bool,
        h265Hardware: Bool,
        maxWidth: UInt32,
        maxHeight: UInt32,
        maxFPS: UInt32
    ) {
        self.h264Hardware = h264Hardware
        self.h265Hardware = h265Hardware
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFPS = maxFPS
    }
}

public struct HostEncodedAccessUnit: Sendable {
    public let hostInstanceID: String
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec
    public let framing: HostMediaFraming
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let data: Data

    public init(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        displayID: UInt64,
        displayRevision: UInt64,
        codec: HostMediaCodec,
        framing: HostMediaFraming,
        presentationTimeUS: UInt64,
        isKeyframe: Bool,
        hasParameterSets: Bool,
        data: Data
    ) {
        self.hostInstanceID = hostInstanceID
        self.connectionEpoch = connectionEpoch
        self.codecEpoch = codecEpoch
        self.displayID = displayID
        self.displayRevision = displayRevision
        self.codec = codec
        self.framing = framing
        self.presentationTimeUS = presentationTimeUS
        self.isKeyframe = isKeyframe
        self.hasParameterSets = hasParameterSets
        self.data = data
    }
}

/// Decoded minimal snapshot field set (§8.3). Raw JSON is kept for audit
/// logging; the temporary password value is only present for the one-shot
/// revealed copy (§9.2).
public enum HostRecoveryStatus: String, Equatable, Sendable {
    case running
    case suspending
    case suspended
    case resuming
    case failed
}

private func strictSnapshotUInt64(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return nil }
    let unsigned = number.uint64Value
    guard number.decimalValue == Decimal(unsigned) else { return nil }
    return unsigned
}

public struct HostCoreSnapshot: Sendable {
    public let schemaVersion: Int
    public let hostInstanceId: String
    public let hostState: String
    public let localId: String
    public let registrationStatus: String
    public let recoveryEpoch: UInt64
    public let recoveryStatus: HostRecoveryStatus
    public let pendingApproval: HostPendingApproval?
    public let activeSession: HostActiveSession?
    public let temporaryPasswordPolicy: String
    public let revealedTemporaryPassword: String?
    public let passwordPolicy: HostPermanentPasswordPolicy
    public let lastError: String?
    public let observedAt: UInt64
    public let rawJSON: Data

    public init(rawJSON: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let json = object as? [String: Any]
        else {
            throw HostControlError.snapshotDecode("snapshot is not a JSON object")
        }
        guard (json["schemaVersion"] as? NSNumber)?.intValue == 6,
              let hostInstanceID = json["hostInstanceId"] as? String,
              !hostInstanceID.isEmpty,
              let hostState = json["hostState"] as? String,
              !hostState.isEmpty,
              let localID = json["localId"] as? String,
              let registrationStatus = json["registrationStatus"] as? String,
              !registrationStatus.isEmpty,
              let recoveryEpoch = strictSnapshotUInt64(json["recoveryEpoch"]),
              let recoveryStatusValue = json["recoveryStatus"] as? String,
              let recoveryStatus = HostRecoveryStatus(rawValue: recoveryStatusValue),
              let observedAt = (json["observedAt"] as? NSNumber)?.uint64Value,
              observedAt > 0,
              let presentation = json["temporaryPasswordPresentation"] as? [String: Any],
              let temporaryPasswordPolicy = presentation["policy"] as? String,
              ["redacted", "revealed"].contains(temporaryPasswordPolicy),
              let passwordPolicyJSON = json["passwordPolicy"] as? [String: Any],
              let strengthPolicy = passwordPolicyJSON["strengthPolicy"] as? [String: Any],
              let localPasswordSet = passwordPolicyJSON["localPasswordSet"] as? Bool,
              let effectivePasswordSet = passwordPolicyJSON["effectivePasswordSet"] as? Bool,
              let usingPresetPassword = passwordPolicyJSON["usingPresetPassword"] as? Bool,
              let changeAllowed = passwordPolicyJSON["changeAllowed"] as? Bool,
              let strengthPolicyVersion = (strengthPolicy["version"] as? NSNumber)?.intValue,
              let minimumCharacters = (strengthPolicy["minimumCharacters"] as? NSNumber)?.intValue,
              let maximumCharacters = (strengthPolicy["maximumCharacters"] as? NSNumber)?.intValue,
              let maximumUTF8Bytes = (strengthPolicy["maximumUtf8Bytes"] as? NSNumber)?.intValue,
              let rejectsControlCharacters = strengthPolicy["rejectsControlCharacters"] as? Bool,
              let rejectsOuterWhitespace = strengthPolicy["rejectsOuterWhitespace"] as? Bool,
              let pendingValue = json["pendingApproval"],
              let activeSessionValue = json["activeSession"]
        else {
            throw HostControlError.snapshotDecode("snapshot contract is missing or invalid")
        }
        let revealedTemporaryPassword: String?
        if temporaryPasswordPolicy == "revealed" {
            guard let value = presentation["value"] as? String, !value.isEmpty else {
                throw HostControlError.snapshotDecode(
                    "revealed temporary password is missing"
                )
            }
            revealedTemporaryPassword = value
        } else {
            guard presentation["value"] == nil else {
                throw HostControlError.snapshotDecode(
                    "redacted temporary password contains a value"
                )
            }
            revealedTemporaryPassword = nil
        }
        let pendingApproval: HostPendingApproval?
        if pendingValue is NSNull {
            pendingApproval = nil
        } else if let pendingJSON = pendingValue as? [String: Any],
                  let pending = HostPendingApproval(json: pendingJSON)
        {
            pendingApproval = pending
        } else {
            throw HostControlError.snapshotDecode("pending approval is invalid")
        }
        let activeSession: HostActiveSession?
        if activeSessionValue is NSNull {
            activeSession = nil
        } else if let activeSessionJSON = activeSessionValue as? [String: Any],
                  let session = HostActiveSession(
                      json: activeSessionJSON,
                      hostInstanceID: hostInstanceID
                  )
        {
            activeSession = session
        } else {
            throw HostControlError.snapshotDecode("active session is invalid")
        }
        if let lastError = json["lastError"], !(lastError is NSNull), !(lastError is String) {
            throw HostControlError.snapshotDecode("snapshot last error is invalid")
        }
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
        guard recoveryContractIsValid else {
            throw HostControlError.snapshotDecode("snapshot recovery state is invalid")
        }

        schemaVersion = 6
        hostInstanceId = hostInstanceID
        self.hostState = hostState
        localId = localID
        self.registrationStatus = registrationStatus
        self.recoveryEpoch = recoveryEpoch
        self.recoveryStatus = recoveryStatus
        self.pendingApproval = pendingApproval
        self.activeSession = activeSession
        self.temporaryPasswordPolicy = temporaryPasswordPolicy
        self.revealedTemporaryPassword = revealedTemporaryPassword
        passwordPolicy = HostPermanentPasswordPolicy(
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
        lastError = json["lastError"] as? String
        self.observedAt = observedAt
        self.rawJSON = rawJSON
    }
}

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

    fileprivate init?(json: [String: Any], hostInstanceID: String) {
        let expectedKeys = Set([
            "connectionId", "remoteId", "remoteName", "remotePlatform",
            "remoteMetadataTrust", "startedAt", "initialCapabilities",
            "activeCapabilities", "inputAvailability", "inputUnavailableReason",
        ])
        let allowedCapabilities = Set([
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
            "writeClipboard", "hearSystemAudio",
        ])
        guard Set(json.keys) == expectedKeys,
              let connectionID = json["connectionId"] as? String,
              Self.valid(connectionID, maximumUTF8Bytes: 128, allowEmpty: false),
              connectionID.hasPrefix("\(hostInstanceID):"),
              let remoteID = json["remoteId"] as? String,
              Self.valid(remoteID, maximumUTF8Bytes: 256, allowEmpty: false),
              let remoteName = json["remoteName"] as? String,
              Self.valid(remoteName, maximumUTF8Bytes: 256, allowEmpty: true),
              let remotePlatform = json["remotePlatform"] as? String,
              Self.valid(remotePlatform, maximumUTF8Bytes: 256, allowEmpty: true),
              json["remoteMetadataTrust"] as? String == "untrusted",
              let startedAt = (json["startedAt"] as? NSNumber)?.uint64Value,
              startedAt > 0,
              let initialCapabilities = json["initialCapabilities"] as? [String],
              let activeCapabilities = json["activeCapabilities"] as? [String],
              let inputAvailabilityValue = json["inputAvailability"] as? String,
              let inputAvailability = HostSessionInputAvailability(
                  rawValue: inputAvailabilityValue
              ),
              let inputUnavailableReasonValue = json["inputUnavailableReason"],
              Self.validCapabilities(initialCapabilities, allowed: allowedCapabilities),
              Self.validCapabilities(activeCapabilities, allowed: allowedCapabilities),
              Set(activeCapabilities).isSubset(of: Set(initialCapabilities)),
              let inputUnavailableReason = Self.inputUnavailableReason(
                  from: inputUnavailableReasonValue
              ),
              Self.validInputAvailability(
                  inputAvailability,
                  reason: inputUnavailableReason,
                  controlsKeyboardAndMouse: activeCapabilities.contains(
                      "controlKeyboardMouse"
                  )
              )
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

    private static func inputUnavailableReason(
        from value: Any
    ) -> HostSessionInputUnavailableReason?? {
        if value is NSNull { return .some(nil) }
        guard let rawValue = value as? String,
              let reason = HostSessionInputUnavailableReason(rawValue: rawValue)
        else { return nil }
        return .some(reason)
    }

    private static func validInputAvailability(
        _ availability: HostSessionInputAvailability,
        reason: HostSessionInputUnavailableReason?,
        controlsKeyboardAndMouse: Bool
    ) -> Bool {
        switch (availability, reason, controlsKeyboardAndMouse) {
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

    private static func validCapabilities(
        _ capabilities: [String],
        allowed: Set<String>
    ) -> Bool {
        let capabilitySet = Set(capabilities)
        return (1...16).contains(capabilities.count)
            && capabilitySet.count == capabilities.count
            && capabilitySet.contains("viewDisplay")
            && capabilitySet.isSubset(of: allowed)
            && capabilitySet.contains("readClipboard")
                == capabilitySet.contains("writeClipboard")
    }

    private static func valid(
        _ value: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool
    ) -> Bool {
        (allowEmpty || !value.isEmpty)
            && value.utf8.count <= maximumUTF8Bytes
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

    fileprivate init?(json: [String: Any]) {
        let expectedKeys = Set([
            "connectionId", "remoteId", "remoteName", "remotePlatform",
            "remoteMetadataTrust", "requestedAt", "expiresAt",
            "requestedCapabilities", "transport", "authenticationMethod",
            "riskAlerts",
        ])
        let allowedCapabilities = Set([
            "viewDisplay", "controlKeyboardMouse", "readClipboard",
            "writeClipboard", "hearSystemAudio",
        ])
        guard Set(json.keys) == expectedKeys,
              let connectionID = json["connectionId"] as? String,
              Self.valid(connectionID, maximumUTF8Bytes: 128, allowEmpty: false),
              let remoteID = json["remoteId"] as? String,
              Self.valid(remoteID, maximumUTF8Bytes: 256, allowEmpty: false),
              let remoteName = json["remoteName"] as? String,
              Self.valid(remoteName, maximumUTF8Bytes: 256, allowEmpty: true),
              let remotePlatform = json["remotePlatform"] as? String,
              Self.valid(remotePlatform, maximumUTF8Bytes: 256, allowEmpty: true),
              json["remoteMetadataTrust"] as? String == "untrusted",
              let requestedAt = (json["requestedAt"] as? NSNumber)?.uint64Value,
              requestedAt > 0,
              let expiresAt = (json["expiresAt"] as? NSNumber)?.uint64Value,
              expiresAt > requestedAt,
              let requestedCapabilities = json["requestedCapabilities"] as? [String],
              (1...16).contains(requestedCapabilities.count),
              requestedCapabilities.contains("viewDisplay"),
              Set(requestedCapabilities).count == requestedCapabilities.count,
              requestedCapabilities.allSatisfy(allowedCapabilities.contains),
              let transport = json["transport"] as? String,
              ["direct", "relay", "unknown"].contains(transport),
              let authenticationMethod = json["authenticationMethod"] as? String,
              authenticationMethod == "localApproval",
              let riskAlerts = json["riskAlerts"] as? [String],
              riskAlerts.isEmpty
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

    private static func valid(
        _ value: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool
    ) -> Bool {
        (allowEmpty || !value.isEmpty)
            && value.utf8.count <= maximumUTF8Bytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Keeps UI decisions bound to the exact pending request recovered from the
/// latest Host snapshot. It does not authorize anything itself; Rust remains
/// authoritative for request identity, deadline and final state.
package struct HostApprovalDecisionGate: Sendable {
    package private(set) var currentConnectionID: String?
    package private(set) var decisionInFlightConnectionID: String?
    private var lastNotifiedConnectionID: String?

    package init() {}

    /// Returns true once for each newly observed connection ID so the App can
    /// request local attention without repeating it on every snapshot poll.
    package mutating func observe(connectionID: String?) -> Bool {
        currentConnectionID = connectionID
        if decisionInFlightConnectionID != connectionID {
            decisionInFlightConnectionID = nil
        }
        guard let connectionID,
              connectionID != lastNotifiedConnectionID else { return false }
        lastNotifiedConnectionID = connectionID
        return true
    }

    /// Atomically accepts one local button action only for the current request.
    package mutating func beginDecision(connectionID: String) -> Bool {
        guard currentConnectionID == connectionID,
              decisionInFlightConnectionID == nil else { return false }
        decisionInFlightConnectionID = connectionID
        return true
    }

    package mutating func completeDecision(connectionID: String) {
        guard decisionInFlightConnectionID == connectionID else { return }
        decisionInFlightConnectionID = nil
    }

    package func isResolving(connectionID: String) -> Bool {
        decisionInFlightConnectionID == connectionID
    }

    package mutating func reset() {
        currentConnectionID = nil
        decisionInFlightConnectionID = nil
        lastNotifiedConnectionID = nil
    }
}

package enum HostSessionCommandIntent: Equatable, Sendable {
    case disable(HostSessionRevocableCapability)
    case disconnect
}

/// Serializes local active-session actions and keeps their completion bound to
/// the next authoritative Host snapshot. A successful C call only means the
/// command was queued; it never removes a capability or session optimistically.
package struct HostSessionCommandGate: Sendable {
    package private(set) var currentConnectionID: String?
    package private(set) var commandInFlightConnectionID: String?
    package private(set) var commandInFlightIntent: HostSessionCommandIntent?
    private var currentActiveCapabilities = Set<String>()

    package init() {}

    package mutating func observe(
        connectionID: String?,
        activeCapabilities: [String]
    ) {
        if currentConnectionID != connectionID {
            commandInFlightConnectionID = nil
            commandInFlightIntent = nil
        }
        currentConnectionID = connectionID
        currentActiveCapabilities = connectionID == nil ? [] : Set(activeCapabilities)

        guard commandInFlightConnectionID == connectionID,
              let commandInFlightIntent else {
            if connectionID == nil {
                commandInFlightConnectionID = nil
                self.commandInFlightIntent = nil
            }
            return
        }
        if case .disable(let capability) = commandInFlightIntent,
           capability.snapshotCapabilityNames.isDisjoint(with: currentActiveCapabilities) {
            commandInFlightConnectionID = nil
            self.commandInFlightIntent = nil
        }
    }

    package mutating func begin(
        connectionID: String,
        intent: HostSessionCommandIntent
    ) -> Bool {
        guard currentConnectionID == connectionID,
              commandInFlightConnectionID == nil,
              commandInFlightIntent == nil else { return false }
        if case .disable(let capability) = intent,
           !capability.snapshotCapabilityNames.isSubset(of: currentActiveCapabilities) {
            return false
        }
        commandInFlightConnectionID = connectionID
        commandInFlightIntent = intent
        return true
    }

    package mutating func complete(
        connectionID: String,
        intent: HostSessionCommandIntent
    ) {
        guard commandInFlightConnectionID == connectionID,
              commandInFlightIntent == intent else { return }
        commandInFlightConnectionID = nil
        commandInFlightIntent = nil
    }

    package func isResolving(connectionID: String) -> Bool {
        commandInFlightConnectionID == connectionID
            && commandInFlightIntent != nil
    }

    package func resolvingIntent(
        connectionID: String
    ) -> HostSessionCommandIntent? {
        commandInFlightConnectionID == connectionID
            ? commandInFlightIntent
            : nil
    }

    package mutating func reset() {
        currentConnectionID = nil
        currentActiveCapabilities = []
        commandInFlightConnectionID = nil
        commandInFlightIntent = nil
    }
}

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
              schemaVersion == 1,
              let eventID = (envelope["eventId"] as? NSNumber)?.uint64Value,
              let eventType = envelope["eventType"] as? String,
              !eventType.isEmpty,
              let hostInstanceID = envelope["hostInstanceId"] as? String,
              !hostInstanceID.isEmpty,
              let sentAt = (envelope["sentAt"] as? NSNumber)?.uint64Value,
              sentAt > 0
        else { return nil }
        self.schemaVersion = schemaVersion
        self.eventId = eventID
        self.eventType = eventType
        self.hostInstanceId = hostInstanceID
        self.sentAt = sentAt
        self.rawJSON = rawJSON
    }
}

public struct HostMediaControl: Sendable {
    public enum Command: String, Sendable {
        case startCapture
        case stopCapture
        case reconfigure
        case requestIdr
    }

    public let command: Command
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec?
    public let width: UInt32?
    public let height: UInt32?
    public let framesPerSecond: UInt32?
    public let bitRate: UInt32?
    public let reason: String?
}

/// Low-frequency, sanitized evidence that a compressed access unit crossed
/// the existing RustDesk writer/ACK path. It deliberately contains no peer
/// identifier, encoded bytes, screen content, password, or server material.
public struct HostMediaDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case firstPacketDispatched
        case firstPacketAcknowledged
        case refreshKeyframeDispatched
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec
    public let framing: HostMediaFraming
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let subscriberCount: UInt32
}

/// Low-frequency, aggregate occupancy sampled at the production Rust encoded
/// queue. This event is carried by the existing Host event callback and does
/// not expose payload bytes, peer identity, transport credentials, or server
/// material.
public struct HostMediaQueueDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let currentDepth: UInt32
    public let maximumDepth: UInt32
    public let capacity: UInt32
}

/// Route-scoped cumulative wall-clock measurements from the synchronous
/// RustDesk video-service loop. Dispatch wall covers subscriber channel fanout;
/// confirmation wait covers the existing frame-controller fetch wait. Neither
/// value is encryption CPU time, socket-send time, RTT, nor remote ACK latency.
public struct HostMediaWriterDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let cycles: UInt64
    public let subscriberDispatches: UInt64
    public let dispatchWallTotalUS: UInt64
    public let maximumDispatchWallUS: UInt64
    public let confirmationWaitTotalUS: UInt64
    public let maximumConfirmationWaitUS: UInt64
    public let completedConfirmations: UInt64
    public let timedOutConfirmations: UInt64
}

/// Low-frequency route-scoped network estimates from RustDesk's existing QoS
/// TestDelay path. Missing samples remain nil; no peer identity, transport
/// classification, packet-loss estimate, or server material is exported.
public struct HostMediaNetworkDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let subscriberCount: UInt32
    public let qosSubscriberCount: UInt32
    public let delaySampledSubscribers: UInt32
    public let rttSampledSubscribers: UInt32
    public let responseDelayedSubscribers: UInt32
    public let worstNetworkDelayMS: UInt32?
    public let worstRTTMS: UInt32?
}

/// Route-scoped transport classification retained by the Rust connection
/// lifecycle registry. Only aggregate counts are exported; unknown remains an
/// explicit category instead of being inferred as direct or relay.
public struct HostMediaTransportDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case sample
        case routeStopped
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let subscriberCount: UInt32
    public let directSubscribers: UInt32
    public let relaySubscribers: UInt32
    public let unknownSubscribers: UInt32
}

public extension HostCoreEvent {
    var mediaControl: HostMediaControl? {
        guard eventType == "mediaControl",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawCommand = payload["command"] as? String,
              let command = HostMediaControl.Command(rawValue: rawCommand)
        else { return nil }
        let codec: HostMediaCodec?
        switch payload["codec"] as? String {
        case "h264": codec = .h264
        case "h265": codec = .h265
        default: codec = nil
        }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        func uint32(_ key: String) -> UInt32? {
            guard let value = uint64(key), value <= UInt32.max else { return nil }
            return UInt32(value)
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId")
        else { return nil }
        let displayRevision = uint64("displayRevision") ?? 0
        if command == .reconfigure {
            guard codec != nil,
                  let width = uint32("width"), width > 0,
                  let height = uint32("height"), height > 0,
                  let fps = uint32("fps"), fps > 0,
                  displayRevision > 0
            else { return nil }
        }
        return HostMediaControl(
            command: command,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            codec: codec,
            width: uint32("width"),
            height: uint32("height"),
            framesPerSecond: uint32("fps"),
            bitRate: uint32("bitrate"),
            reason: payload["reason"] as? String
        )
    }

    var mediaDiagnostic: HostMediaDiagnostic? {
        guard eventType == "mediaDiagnostic",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawKind = payload["kind"] as? String,
              let kind = HostMediaDiagnostic.Kind(rawValue: rawKind),
              let codecName = payload["codec"] as? String,
              let framingName = payload["framing"] as? String,
              let isKeyframe = payload["keyframe"] as? Bool,
              let hasParameterSets = payload["hasParameterSets"] as? Bool
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId"),
              let displayRevision = uint64("displayRevision"), displayRevision > 0,
              let presentationTimeUS = uint64("ptsUs"),
              let rawSubscriberCount = uint64("subscriberCount"),
              rawSubscriberCount > 0, rawSubscriberCount <= UInt32.max
        else { return nil }
        let codec: HostMediaCodec
        switch codecName {
        case "h264": codec = .h264
        case "h265": codec = .h265
        default: return nil
        }
        let framing: HostMediaFraming
        switch framingName {
        case "annexB": framing = .annexB
        case "avcc": framing = .avcc
        default: return nil
        }
        return HostMediaDiagnostic(
            kind: kind,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            codec: codec,
            framing: framing,
            presentationTimeUS: presentationTimeUS,
            isKeyframe: isKeyframe,
            hasParameterSets: hasParameterSets,
            subscriberCount: UInt32(rawSubscriberCount)
        )
    }

    var mediaQueueDiagnostic: HostMediaQueueDiagnostic? {
        guard eventType == "mediaQueueDiagnostic",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawKind = payload["kind"] as? String,
              let kind = HostMediaQueueDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId"),
              let displayRevision = uint64("displayRevision"), displayRevision > 0,
              let currentDepth = uint64("currentDepth"), currentDepth <= UInt32.max,
              let maximumDepth = uint64("maximumDepth"), maximumDepth <= UInt32.max,
              let capacity = uint64("capacity"), capacity > 0, capacity <= UInt32.max,
              currentDepth <= maximumDepth,
              maximumDepth <= capacity
        else { return nil }
        return HostMediaQueueDiagnostic(
            kind: kind,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            currentDepth: UInt32(currentDepth),
            maximumDepth: UInt32(maximumDepth),
            capacity: UInt32(capacity)
        )
    }

    var mediaWriterDiagnostic: HostMediaWriterDiagnostic? {
        guard eventType == "mediaWriterDiagnostic",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawKind = payload["kind"] as? String,
              let kind = HostMediaWriterDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId"),
              let displayRevision = uint64("displayRevision"), displayRevision > 0,
              let cycles = uint64("cycles"),
              let subscriberDispatches = uint64("subscriberDispatches"),
              let dispatchWallTotalUS = uint64("dispatchWallTotalUs"),
              let maximumDispatchWallUS = uint64("maximumDispatchWallUs"),
              let confirmationWaitTotalUS = uint64("confirmationWaitTotalUs"),
              let maximumConfirmationWaitUS = uint64("maximumConfirmationWaitUs"),
              let completedConfirmations = uint64("completedConfirmations"),
              let timedOutConfirmations = uint64("timedOutConfirmations"),
              maximumDispatchWallUS <= dispatchWallTotalUS,
              maximumConfirmationWaitUS <= confirmationWaitTotalUS
        else { return nil }
        let (confirmationCycles, overflow) = completedConfirmations.addingReportingOverflow(
            timedOutConfirmations
        )
        guard !overflow, confirmationCycles == cycles else { return nil }
        if cycles == 0 {
            guard subscriberDispatches == 0,
                  dispatchWallTotalUS == 0,
                  maximumDispatchWallUS == 0,
                  confirmationWaitTotalUS == 0,
                  maximumConfirmationWaitUS == 0
            else { return nil }
        } else {
            guard subscriberDispatches >= cycles else { return nil }
        }
        return HostMediaWriterDiagnostic(
            kind: kind,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            cycles: cycles,
            subscriberDispatches: subscriberDispatches,
            dispatchWallTotalUS: dispatchWallTotalUS,
            maximumDispatchWallUS: maximumDispatchWallUS,
            confirmationWaitTotalUS: confirmationWaitTotalUS,
            maximumConfirmationWaitUS: maximumConfirmationWaitUS,
            completedConfirmations: completedConfirmations,
            timedOutConfirmations: timedOutConfirmations
        )
    }

    var mediaNetworkDiagnostic: HostMediaNetworkDiagnostic? {
        guard eventType == "mediaNetworkDiagnostic",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawKind = payload["kind"] as? String,
              let kind = HostMediaNetworkDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        func uint32(_ key: String) -> UInt32? {
            guard let value = uint64(key), value <= UInt32.max else { return nil }
            return UInt32(value)
        }
        func nullableUInt32(_ key: String) -> UInt32?? {
            guard payload.keys.contains(key) else { return nil }
            if payload[key] is NSNull { return .some(nil) }
            guard let value = uint32(key) else { return nil }
            return .some(value)
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId"),
              let displayRevision = uint64("displayRevision"), displayRevision > 0,
              let subscriberCount = uint32("subscriberCount"),
              let qosSubscriberCount = uint32("qosSubscriberCount"),
              let delaySampledSubscribers = uint32("delaySampledSubscribers"),
              let rttSampledSubscribers = uint32("rttSampledSubscribers"),
              let responseDelayedSubscribers = uint32("responseDelayedSubscribers"),
              let parsedNetworkDelay = nullableUInt32("worstNetworkDelayMs"),
              let parsedRTT = nullableUInt32("worstRttMs"),
              qosSubscriberCount <= subscriberCount,
              delaySampledSubscribers <= qosSubscriberCount,
              rttSampledSubscribers <= delaySampledSubscribers,
              responseDelayedSubscribers <= qosSubscriberCount,
              (delaySampledSubscribers == 0) == (parsedNetworkDelay == nil),
              (rttSampledSubscribers == 0) == (parsedRTT == nil)
        else { return nil }
        return HostMediaNetworkDiagnostic(
            kind: kind,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            subscriberCount: subscriberCount,
            qosSubscriberCount: qosSubscriberCount,
            delaySampledSubscribers: delaySampledSubscribers,
            rttSampledSubscribers: rttSampledSubscribers,
            responseDelayedSubscribers: responseDelayedSubscribers,
            worstNetworkDelayMS: parsedNetworkDelay,
            worstRTTMS: parsedRTT
        )
    }

    var mediaTransportDiagnostic: HostMediaTransportDiagnostic? {
        guard eventType == "mediaTransportDiagnostic",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawKind = payload["kind"] as? String,
              let kind = HostMediaTransportDiagnostic.Kind(rawValue: rawKind)
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.int64Value >= 0,
                  number.doubleValue.isFinite,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        func uint32(_ key: String) -> UInt32? {
            guard let value = uint64(key), value <= UInt32.max else { return nil }
            return UInt32(value)
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId"),
              let displayRevision = uint64("displayRevision"), displayRevision > 0,
              let subscriberCount = uint32("subscriberCount"),
              let directSubscribers = uint32("directSubscribers"),
              let relaySubscribers = uint32("relaySubscribers"),
              let unknownSubscribers = uint32("unknownSubscribers"),
              UInt64(directSubscribers) + UInt64(relaySubscribers)
                + UInt64(unknownSubscribers) == UInt64(subscriberCount)
        else { return nil }
        return HostMediaTransportDiagnostic(
            kind: kind,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            subscriberCount: subscriberCount,
            directSubscribers: directSubscribers,
            relaySubscribers: relaySubscribers,
            unknownSubscribers: unknownSubscribers
        )
    }

}

public extension HostMediaControl {
    func matchesRoute(_ other: HostMediaControl) -> Bool {
        connectionEpoch == other.connectionEpoch
            && codecEpoch == other.codecEpoch
            && displayID == other.displayID
            && (displayRevision == 0
                || other.displayRevision == 0
                || displayRevision == other.displayRevision)
    }
}

public extension HostMediaDiagnostic {
    func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch
            && codecEpoch == route.codecEpoch
            && displayID == route.displayID
            && displayRevision == route.displayRevision
    }
}

public extension HostMediaQueueDiagnostic {
    func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch
            && codecEpoch == route.codecEpoch
            && displayID == route.displayID
            && displayRevision == route.displayRevision
    }
}

public extension HostMediaWriterDiagnostic {
    func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch
            && codecEpoch == route.codecEpoch
            && displayID == route.displayID
            && displayRevision == route.displayRevision
    }
}

public extension HostMediaNetworkDiagnostic {
    func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch
            && codecEpoch == route.codecEpoch
            && displayID == route.displayID
            && displayRevision == route.displayRevision
    }
}

public extension HostMediaTransportDiagnostic {
    func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch
            && codecEpoch == route.codecEpoch
            && displayID == route.displayID
            && displayRevision == route.displayRevision
    }
}

private final class HostEventBox: @unchecked Sendable {
    let queue: DispatchQueue
    let onEvent: @Sendable (HostCoreEvent) -> Void

    init(queue: DispatchQueue, onEvent: @escaping @Sendable (HostCoreEvent) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }
}

private let hostEventCallback: RdnHostEventCallback = { context, json, length in
    guard let context, let json, length > 0 else { return }
    let box = Unmanaged<HostEventBox>.fromOpaque(context).takeUnretainedValue()
    // The Rust pointer is callback-scoped; copy the envelope bytes now.
    let data = Data(bytes: json, count: length)
    guard let event = HostCoreEvent(rawJSON: data) else { return }
    box.queue.async { box.onEvent(event) }
}

/// Swift-side HostCore control surface (§6.3, §8.2). Wraps the shimmed
/// `rdn_host_*` ABI with one library handle per process; host and viewer
/// cores remain mutually exclusive (§18 rule 1).
public final class HostControlClient: @unchecked Sendable {
    public static let hostABIVersion = UInt32(RDN_HOST_ABI_VERSION)
    public static let hostMediaABIVersion = UInt32(RDN_HOST_MEDIA_ABI_VERSION)
    public static let expectedUpstreamCommit = RustDeskCoreClient.expectedUpstreamCommit

    private let library: OpaquePointer
    private let eventBox: HostEventBox
    private let lock = NSLock()
    private var host: OpaquePointer?
    private var stopped = false

    public let upstreamCommit: String
    public let hostUpstreamCommit: String

    /// Loads the core library and validates the host ABI surface. Does not
    /// switch the config root and does not create a host instance.
    public init(
        libraryURL: URL,
        eventQueue: DispatchQueue = DispatchQueue(label: "io.farpane.host-events", qos: .userInitiated),
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let library = libraryURL.path.withCString({
            rdn_shim_open($0, &error, error.count)
        }) else {
            throw HostControlError.load(String(cString: error))
        }
        guard rdn_shim_host_available(library) != 0 else {
            rdn_shim_close(library)
            throw HostControlError.hostSurfaceUnavailable
        }
        let hostABI = rdn_shim_host_abi_version(library)
        guard hostABI == Self.hostABIVersion else {
            rdn_shim_close(library)
            throw HostControlError.abiMismatch(found: hostABI)
        }
        let mediaABI = rdn_shim_host_media_abi_version(library)
        guard mediaABI == Self.hostMediaABIVersion else {
            rdn_shim_close(library)
            throw HostControlError.mediaABIMismatch(found: mediaABI)
        }
        let commit = rdn_shim_upstream_commit(library).map { String(cString: $0) } ?? ""
        let hostCommit = rdn_shim_host_upstream_commit(library).map { String(cString: $0) } ?? ""
        guard commit == Self.expectedUpstreamCommit, hostCommit == Self.expectedUpstreamCommit else {
            rdn_shim_close(library)
            throw HostControlError.invalidUpstreamCommit(hostCommit.isEmpty ? commit : hostCommit)
        }
        self.library = library
        self.eventBox = HostEventBox(queue: eventQueue, onEvent: onEvent)
        upstreamCommit = commit
        hostUpstreamCommit = hostCommit
    }

    deinit {
        lock.lock()
        let handle = host
        host = nil
        lock.unlock()
        if let handle {
            rdn_shim_host_stop(library, handle, RDN_HOST_STOP_APP_EXIT)
            rdn_shim_host_destroy(library, handle)
        }
        rdn_shim_close(library)
        withExtendedLifetime(eventBox) {}
    }

    /// One-shot early config-root isolation (decision point B): must run
    /// before any RustDesk config access in the process and before `start()`.
    public func setConfigRoot(appName: String, org: String) throws {
        let result = appName.withCString { name in
            org.withCString { organization in
                rdn_shim_host_set_config_root(library, name, organization)
            }
        }
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.configRoot(result)
        }
    }

    /// Creates and starts the host instance. Requires a successful prior
    /// `setConfigRoot`; the core fails closed otherwise (§8.2).
    public func start(configuration: HostServerConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard host == nil else { return }
        var callbacks = RdnHostCallbacks(
            abi_version: Self.hostABIVersion,
            on_event: hostEventCallback,
            context: Unmanaged.passUnretained(eventBox).toOpaque()
        )
        var handle: OpaquePointer?
        let created = configuration.rendezvousServer.withCString { rendezvousServer in
            configuration.relayServer.withCString { relayServer in
                configuration.serverPublicKey.withCString { serverPublicKey in
                    var options = RdnHostCreateOptions(
                        abi_version: Self.hostABIVersion,
                        rendezvous_server: rendezvousServer,
                        relay_server: relayServer,
                        server_public_key: serverPublicKey
                    )
                    return rdn_shim_host_create(library, &options, &callbacks, &handle)
                }
            }
        }
        guard created == Int32(RDN_HOST_OK), let handle else {
            throw HostControlError.create(created)
        }
        let started = rdn_shim_host_start(library, handle)
        guard started == Int32(RDN_HOST_OK) else {
            rdn_shim_host_destroy(library, handle)
            throw HostControlError.start(started)
        }
        host = handle
        stopped = false
    }

    /// Sends a versioned command envelope (§8.4). `payload` entries are merged
    /// into the envelope body.
    public func command(_ name: String, commandId: String = UUID().uuidString, payload: [String: Any] = [:]) throws {
        let envelope = try HostCommandEnvelopePolicy.envelope(
            commandName: name,
            commandID: commandId,
            payload: payload
        )
        let data = try JSONSerialization.data(withJSONObject: envelope)
        lock.lock()
        let result: Int32
        if let handle = host {
            result = data.withUnsafeBytes { buffer in
                rdn_shim_host_command(
                    library, handle, buffer.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.command(result)
        }
    }

    /// Applies the one final local decision allowed for a pending connection.
    /// Rust remains authoritative for deadline, identity and prior-final state.
    public func resolvePendingApproval(
        connectionID: String,
        decision: HostApprovalDecision,
        commandId: String = UUID().uuidString
    ) throws {
        try command(
            decision.commandName,
            commandId: commandId,
            payload: ["connectionId": connectionID]
        )
    }

    /// Revokes one capability only for the currently active, exact session.
    /// The Rust session broker validates identity and remains authoritative for
    /// the capability snapshot emitted after the connection applies the change.
    public func disableActiveSessionCapability(
        _ capability: HostSessionRevocableCapability,
        connectionID: String,
        commandId: String = UUID().uuidString
    ) throws {
        try command(
            capability.commandName,
            commandId: commandId,
            payload: ["connectionId": connectionID]
        )
    }

    /// Requests ordered connection teardown for the exact active session.
    /// Repeating the request is idempotent while that session is still active.
    public func disconnectSession(
        connectionID: String,
        commandId: String = UUID().uuidString
    ) throws {
        try command(
            "disconnectSession",
            commandId: commandId,
            payload: ["connectionId": connectionID]
        )
    }

    /// Sends a permanent password only through the mutable secret-buffer ABI.
    /// The supplied Data is zeroed on every return path and must not be reused.
    public func setPermanentPassword(
        _ passwordUTF8: inout Data,
        commandId: String = UUID().uuidString
    ) throws {
        let result = HostSecretBufferPolicy.withMutableBytes(&passwordUTF8) { bytes, count in
            lock.lock()
            defer { lock.unlock() }
            guard let handle = host else { return Int32(RDN_HOST_ERR_BAD_STATE) }
            return commandId.withCString { commandID in
                rdn_shim_host_set_permanent_password(
                    library, handle, commandID, bytes, count)
            }
        }
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.permanentPassword(result)
        }
    }

    /// Copies the current snapshot (§8.3). The revealed temporary password is
    /// only present on the single copy following a reveal command (§9.2).
    public func copySnapshot() throws -> HostCoreSnapshot {
        var bytes = RdnHostOwnedBytes(data: nil, length: 0, capacity: 0)
        lock.lock()
        let result = host.map {
            rdn_shim_host_copy_snapshot(library, $0, &bytes)
        } ?? Int32(RDN_HOST_ERR_BAD_STATE)
        lock.unlock()
        guard result == Int32(RDN_HOST_OK), let data = bytes.data else {
            throw HostControlError.snapshot(result)
        }
        let payload = Data(bytes: data, count: bytes.length)
        rdn_shim_host_free_bytes(library, bytes)
        return try HostCoreSnapshot(rawJSON: payload)
    }

    public func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        lock.lock()
        let result: Int32
        if let handle = host {
            result = hostInstanceID.withCString { instanceID in
                var raw = RdnHostEncoderCapabilities(
                    abi_version: Self.hostMediaABIVersion,
                    host_instance_id: instanceID,
                    h264_hardware: capabilities.h264Hardware ? 1 : 0,
                    h265_hardware: capabilities.h265Hardware ? 1 : 0,
                    max_width: capabilities.maxWidth,
                    max_height: capabilities.maxHeight,
                    max_fps: capabilities.maxFPS
                )
                return rdn_shim_host_media_set_capabilities(library, handle, &raw)
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.media(result) }
    }

    public func submit(accessUnit: HostEncodedAccessUnit) throws {
        var flags: UInt32 = 0
        if accessUnit.isKeyframe { flags |= UInt32(RDN_HOST_MEDIA_FLAG_KEYFRAME) }
        if accessUnit.hasParameterSets { flags |= UInt32(RDN_HOST_MEDIA_FLAG_PARAMETER_SETS) }
        lock.lock()
        let result: Int32
        if let handle = host {
            result = accessUnit.hostInstanceID.withCString { instanceID in
                accessUnit.data.withUnsafeBytes { bytes in
                    var raw = RdnHostEncodedAccessUnit(
                        abi_version: Self.hostMediaABIVersion,
                        host_instance_id: instanceID,
                        connection_epoch: accessUnit.connectionEpoch,
                        codec_epoch: accessUnit.codecEpoch,
                        display_id: accessUnit.displayID,
                        display_revision: accessUnit.displayRevision,
                        codec: RdnHostMediaCodec(rawValue: accessUnit.codec.rawValue),
                        framing: RdnHostMediaFraming(rawValue: accessUnit.framing.rawValue),
                        flags: flags,
                        pts_us: accessUnit.presentationTimeUS,
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: accessUnit.data.count
                    )
                    return rdn_shim_host_media_submit_access_unit(library, handle, &raw)
                }
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.media(result) }
    }

    public func reportEncoderState(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        codec: HostMediaCodec,
        hardwareAccelerated: Bool,
        softwareFallback: Bool,
        encoderID: String
    ) throws {
        lock.lock()
        let result: Int32
        if let handle = host {
            result = hostInstanceID.withCString { instanceID in
                encoderID.withCString { encoderID in
                    var raw = RdnHostEncoderState(
                        abi_version: Self.hostMediaABIVersion,
                        host_instance_id: instanceID,
                        connection_epoch: connectionEpoch,
                        codec_epoch: codecEpoch,
                        codec: RdnHostMediaCodec(rawValue: codec.rawValue),
                        hardware_accelerated: hardwareAccelerated ? 1 : 0,
                        software_fallback: softwareFallback ? 1 : 0,
                        encoder_id: encoderID
                    )
                    return rdn_shim_host_media_report_encoder_state(library, handle, &raw)
                }
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.media(result) }
    }

    /// Stops the host and releases the instance slot; the core rotates the
    /// temporary password on stop (§9.2). Idempotent.
    public func stop(reason: HostStopReason = .userRequest) throws {
        lock.lock()
        let handle = host
        host = nil
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard let handle, !alreadyStopped else { return }
        let result = rdn_shim_host_stop(library, handle, RdnHostStopReason(rawValue: reason.rawValue))
        rdn_shim_host_destroy(library, handle)
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.stop(result)
        }
    }
}
