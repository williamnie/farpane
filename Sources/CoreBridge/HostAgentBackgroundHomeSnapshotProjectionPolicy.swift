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
        activeSession: nil
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

    package init(
        isAvailable: Bool,
        localID: String,
        localPermanentPasswordSet: Bool,
        effectivePermanentPasswordSet: Bool,
        usingPresetPassword: Bool,
        permanentPasswordChangeAllowed: Bool,
        hasRuntimeError: Bool,
        pendingApproval: HostAgentXPCWirePendingApproval? = nil,
        activeSession: HostAgentXPCWireActiveSession? = nil
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
            pendingApproval: payload.pendingApproval,
            activeSession: payload.activeSession
        )
    }

}
