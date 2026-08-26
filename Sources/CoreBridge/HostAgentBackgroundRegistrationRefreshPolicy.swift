package enum HostAgentBackgroundRegistrationRefreshDecision:
    Equatable,
    Sendable
{
    case noAction
    case refresh(buildIdentifier: String)
}

/// Refreshes an already-enabled SMAppService registration exactly once after
/// the containing App build changes. ServiceManagement can otherwise retain
/// the previous parent bundle after an in-place App upgrade while still
/// reporting `.enabled`.
package enum HostAgentBackgroundRegistrationRefreshPolicy {
    package static func decision(
        registration: HostAgentBackgroundRegistrationStatus,
        currentBuildIdentifier: String?,
        registeredBuildIdentifier: String?,
        alreadyAttempted: Bool
    ) -> HostAgentBackgroundRegistrationRefreshDecision {
        guard registration == .enabled,
              !alreadyAttempted,
              let currentBuildIdentifier,
              HostAgentRegistrationBundlePreflight.validBuildIdentifier(
                  currentBuildIdentifier
              ),
              registeredBuildIdentifier != currentBuildIdentifier
        else { return .noAction }
        return .refresh(buildIdentifier: currentBuildIdentifier)
    }
}
