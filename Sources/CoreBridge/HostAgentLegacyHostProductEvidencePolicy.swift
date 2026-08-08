package enum HostAgentLegacyHostSessionObservation: Equatable, Sendable {
    case unavailable
    case available(pendingApproval: Bool, activeSession: Bool)
}

package struct HostAgentLegacyHostProductObservation: Equatable, Sendable {
    package let preferenceEnabled: Bool
    package let runtimeActive: Bool
    package let clientRetained: Bool
    package let session: HostAgentLegacyHostSessionObservation
    package let mediaPipelineActive: Bool
    package let pollerActive: Bool
    package let runtimeQuiescenceConfirmed: Bool

    package init(
        preferenceEnabled: Bool,
        runtimeActive: Bool,
        clientRetained: Bool,
        session: HostAgentLegacyHostSessionObservation,
        mediaPipelineActive: Bool,
        pollerActive: Bool,
        runtimeQuiescenceConfirmed: Bool
    ) {
        self.preferenceEnabled = preferenceEnabled
        self.runtimeActive = runtimeActive
        self.clientRetained = clientRetained
        self.session = session
        self.mediaPipelineActive = mediaPipelineActive
        self.pollerActive = pollerActive
        self.runtimeQuiescenceConfirmed = runtimeQuiescenceConfirmed
    }
}

/// Converts the App's live in-process Host observation into the seven
/// independent migration signals. A failed Core stop makes runtime and session
/// ownership unavailable even if local references have already been cleared.
package enum HostAgentLegacyHostProductEvidencePolicy {
    package static let unavailableEvidence =
        HostAgentLegacyHostMigrationEvidence(
            preferenceEnabled: .unavailable,
            runtimeActive: .unavailable,
            clientRetained: .unavailable,
            pendingApproval: .unavailable,
            activeSession: .unavailable,
            mediaPipelineActive: .unavailable,
            pollerActive: .unavailable
        )

    package static func evidence(
        _ observation: HostAgentLegacyHostProductObservation
    ) -> HostAgentLegacyHostMigrationEvidence {
        let sessionEvidence = sessionEvidence(for: observation)
        return HostAgentLegacyHostMigrationEvidence(
            preferenceEnabled: status(observation.preferenceEnabled),
            runtimeActive: observation.runtimeQuiescenceConfirmed
                ? status(observation.runtimeActive)
                : .unavailable,
            clientRetained: status(observation.clientRetained),
            pendingApproval: sessionEvidence.pendingApproval,
            activeSession: sessionEvidence.activeSession,
            mediaPipelineActive: status(observation.mediaPipelineActive),
            pollerActive: status(observation.pollerActive)
        )
    }

    private static func sessionEvidence(
        for observation: HostAgentLegacyHostProductObservation
    ) -> (
        pendingApproval: HostAgentLegacyHostMigrationEvidenceStatus,
        activeSession: HostAgentLegacyHostMigrationEvidenceStatus
    ) {
        guard observation.runtimeQuiescenceConfirmed else {
            return (.unavailable, .unavailable)
        }
        switch observation.session {
        case .available(let pendingApproval, let activeSession):
            return (status(pendingApproval), status(activeSession))
        case .unavailable:
            return observation.runtimeActive
                ? (.unavailable, .unavailable)
                : (.absent, .absent)
        }
    }

    private static func status(
        _ present: Bool
    ) -> HostAgentLegacyHostMigrationEvidenceStatus {
        present ? .present : .absent
    }
}
