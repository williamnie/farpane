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
    case networkPathRecovery(Int32)
    case sleepRecovery(HostSleepRecoveryOperation, Int32)
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
        case .networkPathRecovery(let code): return "host network-path recovery rejected: \(code)"
        case .sleepRecovery(let operation, let code):
            return "host \(operation.rawValue) rejected: \(code)"
        case .stop(let code): return "host stop failed: \(code)"
        case .media(let code): return "host media operation rejected: \(code)"
        }
    }

    public var isExpectedMediaDrop: Bool {
        guard case .media(let code) = self else { return false }
        return code == Int32(RDN_HOST_ERR_BACKPRESSURE) || code == Int32(RDN_HOST_ERR_STALE_EPOCH)
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

    public var sleepRecoveryFailure: HostSleepRecoveryFailure? {
        guard case .sleepRecovery(_, let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_INVALID_ARG): return .invalidEpoch
        case Int32(RDN_HOST_ERR_STALE_EPOCH): return .staleEpoch
        case Int32(RDN_HOST_ERR_BAD_STATE): return .invalidState
        case Int32(RDN_HOST_ERR_NOT_SUPPORTED): return .unsupported
        case Int32(RDN_HOST_ERR_INTERNAL): return .internalFailure
        default: return .unknown
        }
    }

    public var networkPathRecoveryFailure: HostNetworkPathRecoveryFailure? {
        guard case .networkPathRecovery(let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_STALE_GENERATION): return .staleGeneration
        case Int32(RDN_HOST_ERR_BAD_STATE): return .invalidState
        case Int32(RDN_HOST_ERR_NOT_SUPPORTED): return .unsupported
        case Int32(RDN_HOST_ERR_INTERNAL): return .internalFailure
        default: return .unknown
        }
    }

    /// Classifies only stable Host Media submit rejections whose production
    /// meaning is known. Internal or future codes stay nil so telemetry cannot
    /// turn an unknown failure into a misleading zero/known drop reason.
    package var mediaSubmissionDropReason: HostMediaSubmissionDropReason? {
        guard case .media(let code) = self else { return nil }
        switch code {
        case Int32(RDN_HOST_ERR_BACKPRESSURE): return .networkBackpressure
        case Int32(RDN_HOST_ERR_STALE_EPOCH): return .reconfigure
        case Int32(RDN_HOST_ERR_BAD_STATE): return .shutdown
        case Int32(RDN_HOST_ERR_INVALID_ARG), Int32(RDN_HOST_ERR_ABI_MISMATCH),
            Int32(RDN_HOST_ERR_NOT_SUPPORTED), Int32(RDN_HOST_ERR_VALIDATION),
            Int32(RDN_HOST_ERR_PACKET_TOO_LARGE), Int32(RDN_HOST_ERR_NON_MONOTONIC_PTS),
            Int32(RDN_HOST_ERR_MISSING_PARAMETER_SETS), Int32(RDN_HOST_ERR_CODEC_MISMATCH):
            return .invalidFrame
        default: return nil
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

    var commandName: String {
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
    case clipboardRead
    case clipboardWrite
    case clipboard
    case systemAudio

    package var commandName: String {
        switch self {
        case .keyboardAndMouse: return "disableInputForActiveSession"
        case .clipboardRead: return "disableClipboardReadForActiveSession"
        case .clipboardWrite: return "disableClipboardWriteForActiveSession"
        case .clipboard: return "disableClipboardForActiveSession"
        case .systemAudio: return "disableAudioForActiveSession"
        }
    }

    package var snapshotCapabilityNames: Set<String> {
        switch self {
        case .keyboardAndMouse: return ["controlKeyboardMouse"]
        case .clipboardRead: return ["readClipboard"]
        case .clipboardWrite: return ["writeClipboard"]
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
