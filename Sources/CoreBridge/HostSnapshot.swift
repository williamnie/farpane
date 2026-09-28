import CoreBridgeShim
import Foundation

public enum HostRecoveryStatus: String, Equatable, Sendable {
    case running
    case suspending
    case suspended
    case resuming
    case failed
}

func strictSnapshotUInt64(_ value: Any?) -> UInt64? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        return nil
    }
    let unsigned = number.uint64Value
    guard number.decimalValue == Decimal(unsigned) else { return nil }
    return unsigned
}

public struct HostCoreSnapshot: Sendable {
    public let schemaVersion: Int
    public let hostInstanceId: String
    public let hostState: String
    public let localId: String
    public let authenticatedConnectionCount: UInt64
    public let sessionAvailability: HostSessionAvailability
    public let sessionUnavailableReason: HostSessionUnavailableReason?
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
        else { throw HostControlError.snapshotDecode("snapshot is not a JSON object") }
        guard (json["schemaVersion"] as? NSNumber)?.intValue == 8,
            let hostInstanceID = json["hostInstanceId"] as? String, !hostInstanceID.isEmpty,
            let hostState = json["hostState"] as? String, !hostState.isEmpty,
            let localID = json["localId"] as? String,
            let authenticatedConnectionCount = strictSnapshotUInt64(
                json["authenticatedConnectionCount"]),
            let sessionAvailabilityValue = json["sessionAvailability"] as? String,
            let sessionAvailability = HostSessionAvailability(rawValue: sessionAvailabilityValue),
            let sessionUnavailableReasonValue = json["sessionUnavailableReason"],
            let registrationStatus = json["registrationStatus"] as? String,
            !registrationStatus.isEmpty,
            let recoveryEpoch = strictSnapshotUInt64(json["recoveryEpoch"]),
            let recoveryStatusValue = json["recoveryStatus"] as? String,
            let recoveryStatus = HostRecoveryStatus(rawValue: recoveryStatusValue),
            let observedAt = (json["observedAt"] as? NSNumber)?.uint64Value, observedAt > 0,
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
        else { throw HostControlError.snapshotDecode("snapshot contract is missing or invalid") }
        let sessionUnavailableReason: HostSessionUnavailableReason?
        if sessionUnavailableReasonValue is NSNull {
            sessionUnavailableReason = nil
        } else if let rawValue = sessionUnavailableReasonValue as? String,
            let reason = HostSessionUnavailableReason(rawValue: rawValue)
        {
            sessionUnavailableReason = reason
        } else {
            throw HostControlError.snapshotDecode("snapshot session unavailable reason is invalid")
        }
        switch (sessionAvailability, sessionUnavailableReason) {
        case (.available, nil), (.limited, .sessionUnavailable): break
        default:
            throw HostControlError.snapshotDecode("snapshot session availability tuple is invalid")
        }
        let revealedTemporaryPassword: String?
        if temporaryPasswordPolicy == "revealed" {
            guard let value = presentation["value"] as? String, !value.isEmpty else {
                throw HostControlError.snapshotDecode("revealed temporary password is missing")
            }
            revealedTemporaryPassword = value
        } else {
            guard presentation["value"] == nil else {
                throw HostControlError.snapshotDecode(
                    "redacted temporary password contains a value")
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
            let session = HostActiveSession(json: activeSessionJSON, hostInstanceID: hostInstanceID)
        {
            activeSession = session
        } else {
            throw HostControlError.snapshotDecode("active session is invalid")
        }
        guard activeSession == nil || authenticatedConnectionCount > 0 else {
            throw HostControlError.snapshotDecode(
                "active session requires an authenticated connection")
        }
        if let lastError = json["lastError"], !(lastError is NSNull), !(lastError is String) {
            throw HostControlError.snapshotDecode("snapshot last error is invalid")
        }
        let recoveryContractIsValid: Bool
        switch recoveryStatus {
        case .running: recoveryContractIsValid = true
        case .suspending:
            recoveryContractIsValid =
                recoveryEpoch > 0 && hostState == "starting" && registrationStatus == "suspending"
        case .suspended:
            recoveryContractIsValid =
                recoveryEpoch > 0 && hostState == "starting" && registrationStatus == "suspended"
        case .resuming:
            recoveryContractIsValid =
                recoveryEpoch > 0 && hostState == "starting" && registrationStatus == "pending"
        case .failed:
            recoveryContractIsValid = hostState == "error" && registrationStatus == "degraded"
        }
        guard recoveryContractIsValid else {
            throw HostControlError.snapshotDecode("snapshot recovery state is invalid")
        }

        schemaVersion = 8
        hostInstanceId = hostInstanceID
        self.hostState = hostState
        localId = localID
        self.authenticatedConnectionCount = authenticatedConnectionCount
        self.sessionAvailability = sessionAvailability
        self.sessionUnavailableReason = sessionUnavailableReason
        self.registrationStatus = registrationStatus
        self.recoveryEpoch = recoveryEpoch
        self.recoveryStatus = recoveryStatus
        self.pendingApproval = pendingApproval
        self.activeSession = activeSession
        self.temporaryPasswordPolicy = temporaryPasswordPolicy
        self.revealedTemporaryPassword = revealedTemporaryPassword
        passwordPolicy = HostPermanentPasswordPolicy(
            localPasswordSet: localPasswordSet, effectivePasswordSet: effectivePasswordSet,
            usingPresetPassword: usingPresetPassword, changeAllowed: changeAllowed,
            strengthPolicyVersion: strengthPolicyVersion, minimumCharacters: minimumCharacters,
            maximumCharacters: maximumCharacters, maximumUTF8Bytes: maximumUTF8Bytes,
            rejectsControlCharacters: rejectsControlCharacters,
            rejectsOuterWhitespace: rejectsOuterWhitespace)
        lastError = json["lastError"] as? String
        self.observedAt = observedAt
        self.rawJSON = rawJSON
    }
}
