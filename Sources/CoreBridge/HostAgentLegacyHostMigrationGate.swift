package enum HostAgentLegacyHostMigrationEvidenceStatus:
    Equatable,
    Sendable
{
    case absent
    case present
    case unavailable
}

package struct HostAgentLegacyHostMigrationEvidence: Equatable, Sendable {
    package let preferenceEnabled: HostAgentLegacyHostMigrationEvidenceStatus
    package let runtimeActive: HostAgentLegacyHostMigrationEvidenceStatus
    package let clientRetained: HostAgentLegacyHostMigrationEvidenceStatus
    package let pendingApproval: HostAgentLegacyHostMigrationEvidenceStatus
    package let activeSession: HostAgentLegacyHostMigrationEvidenceStatus
    package let mediaPipelineActive: HostAgentLegacyHostMigrationEvidenceStatus
    package let pollerActive: HostAgentLegacyHostMigrationEvidenceStatus

    package init(
        preferenceEnabled: HostAgentLegacyHostMigrationEvidenceStatus,
        runtimeActive: HostAgentLegacyHostMigrationEvidenceStatus,
        clientRetained: HostAgentLegacyHostMigrationEvidenceStatus,
        pendingApproval: HostAgentLegacyHostMigrationEvidenceStatus,
        activeSession: HostAgentLegacyHostMigrationEvidenceStatus,
        mediaPipelineActive: HostAgentLegacyHostMigrationEvidenceStatus,
        pollerActive: HostAgentLegacyHostMigrationEvidenceStatus
    ) {
        self.preferenceEnabled = preferenceEnabled
        self.runtimeActive = runtimeActive
        self.clientRetained = clientRetained
        self.pendingApproval = pendingApproval
        self.activeSession = activeSession
        self.mediaPipelineActive = mediaPipelineActive
        self.pollerActive = pollerActive
    }
}

package enum HostAgentLegacyHostMigrationBlocker:
    Equatable,
    Hashable,
    Sendable
{
    case preferenceEnabled
    case runtimeActive
    case clientRetained
    case pendingApproval
    case activeSession
    case mediaPipelineActive
    case pollerActive
}

package enum HostAgentLegacyHostMigrationFailure: Equatable, Sendable {
    case evidenceUnavailable
    case inconsistentEvidence
}

package enum HostAgentLegacyHostMigrationAssessment: Equatable, Sendable {
    case eligible
    case blocked(Set<HostAgentLegacyHostMigrationBlocker>)
    case failed(HostAgentLegacyHostMigrationFailure)
}

/// Read-only, fail-closed proof that the in-process Host no longer owns any
/// durable intent, runtime, session, media, client or polling responsibility.
package enum HostAgentLegacyHostMigrationGate {
    package static func assess(
        _ evidence: HostAgentLegacyHostMigrationEvidence
    ) -> HostAgentLegacyHostMigrationAssessment {
        let statuses = [
            evidence.preferenceEnabled,
            evidence.runtimeActive,
            evidence.clientRetained,
            evidence.pendingApproval,
            evidence.activeSession,
            evidence.mediaPipelineActive,
            evidence.pollerActive,
        ]
        guard !statuses.contains(.unavailable) else {
            return .failed(.evidenceUnavailable)
        }
        guard isConsistent(evidence) else {
            return .failed(.inconsistentEvidence)
        }

        var blockers: Set<HostAgentLegacyHostMigrationBlocker> = []
        appendBlocker(
            .preferenceEnabled,
            when: evidence.preferenceEnabled,
            to: &blockers
        )
        appendBlocker(
            .runtimeActive,
            when: evidence.runtimeActive,
            to: &blockers
        )
        appendBlocker(
            .clientRetained,
            when: evidence.clientRetained,
            to: &blockers
        )
        appendBlocker(
            .pendingApproval,
            when: evidence.pendingApproval,
            to: &blockers
        )
        appendBlocker(
            .activeSession,
            when: evidence.activeSession,
            to: &blockers
        )
        appendBlocker(
            .mediaPipelineActive,
            when: evidence.mediaPipelineActive,
            to: &blockers
        )
        appendBlocker(
            .pollerActive,
            when: evidence.pollerActive,
            to: &blockers
        )
        return blockers.isEmpty ? .eligible : .blocked(blockers)
    }

    private static func isConsistent(
        _ evidence: HostAgentLegacyHostMigrationEvidence
    ) -> Bool {
        let runtimeOwnedEvidence = [
            evidence.pendingApproval,
            evidence.activeSession,
            evidence.mediaPipelineActive,
            evidence.pollerActive,
        ]
        if evidence.runtimeActive == .absent,
           runtimeOwnedEvidence.contains(.present) {
            return false
        }

        let clientOwnedEvidence = [
            evidence.runtimeActive,
            evidence.pendingApproval,
            evidence.activeSession,
            evidence.mediaPipelineActive,
            evidence.pollerActive,
        ]
        if evidence.clientRetained == .absent,
           clientOwnedEvidence.contains(.present) {
            return false
        }
        return true
    }

    private static func appendBlocker(
        _ blocker: HostAgentLegacyHostMigrationBlocker,
        when status: HostAgentLegacyHostMigrationEvidenceStatus,
        to blockers: inout Set<HostAgentLegacyHostMigrationBlocker>
    ) {
        if status == .present {
            blockers.insert(blocker)
        }
    }
}
