package enum HostAgentBackgroundRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case enabled
    case serviceUnavailable
}

package enum HostAgentBackgroundHandshakeStatus: Equatable, Sendable {
    case disconnected
    case incompatible
    case compatible
}

package enum HostAgentBackgroundSnapshotStatus: Equatable, Sendable {
    case unavailable
    case available
}

package enum HostAgentBackgroundRendezvousStatus: Equatable, Sendable {
    case checking
    case offline
    case registered
}

package enum HostAgentBackgroundSessionStatus: Equatable, Sendable {
    case unavailable
    case available
    case limitedSessionUnavailable
}

package enum HostAgentBackgroundAvailability: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case serviceUnavailable
    case waitingForHandshake
    case incompatible
    case waitingForSnapshot
    case sessionUnavailable
    case rendezvousUnavailable
    case runtimeEvidenceInvalid
    case ready
}

/// Pure App-side policy for composing independent background-component
/// evidence. Registration or process reachability alone can never become
/// `ready`; the authenticated handshake, authoritative snapshot and
/// Rendezvous registration must all be healthy in the same observation.
package struct HostAgentBackgroundComponentHealth: Equatable, Sendable {
    package let registration: HostAgentBackgroundRegistrationStatus
    package let handshake: HostAgentBackgroundHandshakeStatus
    package let snapshot: HostAgentBackgroundSnapshotStatus
    package let session: HostAgentBackgroundSessionStatus
    package let rendezvous: HostAgentBackgroundRendezvousStatus

    package init(
        registration: HostAgentBackgroundRegistrationStatus,
        handshake: HostAgentBackgroundHandshakeStatus,
        snapshot: HostAgentBackgroundSnapshotStatus,
        session: HostAgentBackgroundSessionStatus,
        rendezvous: HostAgentBackgroundRendezvousStatus
    ) {
        self.registration = registration
        self.handshake = handshake
        self.snapshot = snapshot
        self.session = session
        self.rendezvous = rendezvous
    }

    package var availability: HostAgentBackgroundAvailability {
        guard (snapshot == .unavailable && session == .unavailable)
                || (snapshot == .available && session != .unavailable)
        else { return .runtimeEvidenceInvalid }

        switch registration {
        case .notRegistered:
            return .notRegistered
        case .requiresApproval:
            return .requiresApproval
        case .serviceUnavailable:
            return .serviceUnavailable
        case .enabled:
            break
        }

        switch handshake {
        case .disconnected:
            return .waitingForHandshake
        case .incompatible:
            return .incompatible
        case .compatible:
            break
        }

        guard snapshot == .available else {
            return .waitingForSnapshot
        }
        switch session {
        case .unavailable:
            return .runtimeEvidenceInvalid
        case .limitedSessionUnavailable:
            return .sessionUnavailable
        case .available:
            break
        }
        guard rendezvous == .registered else {
            return .rendezvousUnavailable
        }
        return .ready
    }

    package var isReady: Bool { availability == .ready }
}
