package struct HostAgentBackgroundHomeSnapshotPresentation:
    Equatable,
    Sendable
{
    package static let unavailable = Self(
        isAvailable: false,
        localID: "",
        localPermanentPasswordSet: false,
        effectivePermanentPasswordSet: false,
        usingPresetPassword: false,
        permanentPasswordChangeAllowed: false,
        hasRuntimeError: false,
        pendingApproval: nil,
        activeSession: nil,
        activeSessionPresentation: nil,
        allowsSessionMutationCommands: false
    )

    package let isAvailable: Bool
    package let localID: String
    package let localPermanentPasswordSet: Bool
    package let effectivePermanentPasswordSet: Bool
    package let usingPresetPassword: Bool
    package let permanentPasswordChangeAllowed: Bool
    package let hasRuntimeError: Bool
    package let pendingApproval: HostAgentXPCWirePendingApproval?
    package let activeSession: HostAgentXPCWireActiveSession?
    package let activeSessionPresentation: HostSessionInputPresentation?
    package let allowsSessionMutationCommands: Bool

    package init(
        isAvailable: Bool,
        localID: String,
        localPermanentPasswordSet: Bool,
        effectivePermanentPasswordSet: Bool,
        usingPresetPassword: Bool,
        permanentPasswordChangeAllowed: Bool,
        hasRuntimeError: Bool,
        pendingApproval: HostAgentXPCWirePendingApproval? = nil,
        activeSession: HostAgentXPCWireActiveSession? = nil,
        activeSessionPresentation: HostSessionInputPresentation? = nil,
        allowsSessionMutationCommands: Bool = false
    ) {
        self.isAvailable = isAvailable
        self.localID = localID
        self.localPermanentPasswordSet = localPermanentPasswordSet
        self.effectivePermanentPasswordSet = effectivePermanentPasswordSet
        self.usingPresetPassword = usingPresetPassword
        self.permanentPasswordChangeAllowed =
            permanentPasswordChangeAllowed
        self.hasRuntimeError = hasRuntimeError
        self.pendingApproval = pendingApproval
        self.activeSession = activeSession
        self.activeSessionPresentation = activeSessionPresentation
        self.allowsSessionMutationCommands = allowsSessionMutationCommands
    }
}

/// Read-only Home projection from one coherent activation/runtime snapshot.
/// Temporary passwords and media are deliberately omitted. Approval/session
/// payloads remain data-only; command eligibility is owned by the separate
/// typed command presentation policy.
package enum HostAgentBackgroundHomeSnapshotProjectionPolicy {
    package static func presentation(
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?
    ) -> HostAgentBackgroundHomeSnapshotPresentation {
        guard case .monitoring(_, let readiness) = phase,
              readiness.failure == nil,
              readiness.registration == .enabled,
              let projection,
              projection.generation
                == readiness.runtime.projectionGeneration,
              HostAgentBackgroundRuntimeEvidence(projection: projection)
                == readiness.runtime,
              case .available(let available) = projection.phase
        else {
            return .unavailable
        }
        let payload = available.payload
        let pendingApproval = payload.sessionAvailability == .available
            ? payload.pendingApproval
            : nil
        let activeSessionPresentation = payload.activeSession.flatMap {
            HostSessionPresentationPolicy.presentation(
                sessionAvailability: payload.sessionAvailability,
                sessionUnavailableReason: payload.sessionUnavailableReason,
                inputAvailability: $0.inputAvailability,
                inputUnavailableReason: $0.inputUnavailableReason
            )
        }
        guard payload.activeSession == nil
                || activeSessionPresentation != nil
        else { return .unavailable }
        return HostAgentBackgroundHomeSnapshotPresentation(
            isAvailable: true,
            localID: payload.localID,
            localPermanentPasswordSet:
                payload.passwordPolicy.localPasswordSet,
            effectivePermanentPasswordSet:
                payload.passwordPolicy.effectivePasswordSet,
            usingPresetPassword:
                payload.passwordPolicy.usingPresetPassword,
            permanentPasswordChangeAllowed:
                payload.passwordPolicy.changeAllowed,
            hasRuntimeError: payload.lastError != nil,
            pendingApproval: pendingApproval,
            activeSession: payload.activeSession,
            activeSessionPresentation: activeSessionPresentation,
            allowsSessionMutationCommands:
                payload.sessionAvailability == .available
        )
    }

}
