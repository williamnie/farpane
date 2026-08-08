import Foundation

/// Product-level inbound approval modes from Host Mode §9.4.
///
/// These values are deliberately distinct from RustDesk's three-option
/// `approve-mode`. In particular, `passwordAndLocalApproval` cannot be
/// represented by an upstream config value: it needs a native two-stage gate
/// after password verification and before session authorization.
public enum HostLocalApprovalPath: String, Codable, Sendable {
    case prohibited
    case primary
    case requiredAfterPassword
    case alternativeToPassword
}

public enum HostApprovalMode: String, CaseIterable, Codable, Sendable {
    case manualOnly
    case temporaryPassword
    case permanentPassword
    case passwordAndLocalApproval
    case passwordOrLocalApproval

    public var permitsPasswordAuthentication: Bool {
        self != .manualOnly
    }

    public var permitsLocalApproval: Bool {
        localApprovalPath != .prohibited
    }

    public var requiresLocalApprovalAfterPassword: Bool {
        localApprovalPath == .requiredAfterPassword
    }

    /// The exact point at which a future native broker may accept a local
    /// decision. This prevents an upstream empty-password CM fallback from
    /// silently broadening password-only product modes.
    public var localApprovalPath: HostLocalApprovalPath {
        switch self {
        case .manualOnly:
            .primary
        case .temporaryPassword, .permanentPassword:
            .prohibited
        case .passwordAndLocalApproval:
            .requiredAfterPassword
        case .passwordOrLocalApproval:
            .alternativeToPassword
        }
    }

    /// Whether this mode can authorize while the local user is absent.
    /// Unattended access remains a separate explicit policy switch.
    public var supportsUnattendedAccess: Bool {
        switch self {
        case .temporaryPassword, .permanentPassword, .passwordOrLocalApproval:
            true
        case .manualOnly, .passwordAndLocalApproval:
            false
        }
    }
}

public enum HostApprovalPolicyError: Error, Equatable, CustomStringConvertible {
    case unattendedAccessRequiresPasswordWithoutMandatoryLocalApproval
    case nativeTwoStageGateRequired

    public var description: String {
        switch self {
        case .unattendedAccessRequiresPasswordWithoutMandatoryLocalApproval:
            "unattended access requires a mode that can authorize without local approval"
        case .nativeTwoStageGateRequired:
            "password-and-local approval requires the native two-stage authorization gate"
        }
    }
}

/// Validated product policy. Invalid unattended combinations cannot be
/// represented and therefore cannot leak into later Host command/UI work.
public struct HostApprovalPolicy: Equatable, Sendable {
    public let mode: HostApprovalMode
    public let unattendedAccessEnabled: Bool

    public init(
        mode: HostApprovalMode,
        unattendedAccessEnabled: Bool = false
    ) throws {
        guard !unattendedAccessEnabled || mode.supportsUnattendedAccess else {
            throw HostApprovalPolicyError
                .unattendedAccessRequiresPasswordWithoutMandatoryLocalApproval
        }
        self.mode = mode
        self.unattendedAccessEnabled = unattendedAccessEnabled
    }

    /// Exact config projection available in pinned RustDesk 1.4.9. It is not
    /// sufficient authorization behavior by itself: the future native broker
    /// must also enforce `localApprovalPath`, because upstream can route an
    /// empty-password attempt to its legacy Connection Manager.
    package var upstreamProjection: HostUpstreamApprovalProjection {
        get throws {
            switch mode {
            case .manualOnly:
                return HostUpstreamApprovalProjection(
                    approveMode: .click,
                    verificationMethod: .bothPasswords
                )
            case .temporaryPassword:
                return HostUpstreamApprovalProjection(
                    approveMode: .password,
                    verificationMethod: .temporaryPassword
                )
            case .permanentPassword:
                return HostUpstreamApprovalProjection(
                    approveMode: .password,
                    verificationMethod: .permanentPassword
                )
            case .passwordAndLocalApproval:
                throw HostApprovalPolicyError.nativeTwoStageGateRequired
            case .passwordOrLocalApproval:
                return HostUpstreamApprovalProjection(
                    approveMode: .both,
                    verificationMethod: .bothPasswords
                )
            }
        }
    }
}

package struct HostUpstreamApprovalProjection: Equatable, Sendable {
    package enum ApproveMode: String, Sendable {
        case click
        case password
        case both
    }

    package enum VerificationMethod: String, Sendable {
        case temporaryPassword = "use-temporary-password"
        case permanentPassword = "use-permanent-password"
        case bothPasswords = "use-both-passwords"
    }

    package let approveMode: ApproveMode
    package let verificationMethod: VerificationMethod
}
