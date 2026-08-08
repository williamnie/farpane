package enum HostAgentBackgroundProductRoutingDecision:
    Equatable,
    Sendable
{
    case noChange
    case enableAndRefresh
    case disable
    case invalidCompletion
}

/// Converts only exact terminal UX results into product activation changes.
/// Expected cancellation and mutation failures preserve the current product
/// state; nonterminal or contradictory completions fail closed at the App
/// boundary instead of guessing from a partial observation.
package enum HostAgentBackgroundProductRoutingPolicy {
    package static func registrationDecision(
        _ view: HostAgentBackgroundRegistrationUXView
    ) -> HostAgentBackgroundProductRoutingDecision {
        switch (view.phase, view.registration) {
        case (.registered, .enabled),
             (.navigationRequested, .requiresApproval),
             (.approvalNoLongerRequired, .enabled),
             (.cancelled, .requiresApproval):
            return .enableAndRefresh

        case (.approvalNoLongerRequired, .notRegistered):
            return .disable

        case (.cancelled, nil),
             (.migrationBlocked, nil):
            return .noChange

        case (.failed(.migration), nil):
            return .noChange

        case (
            .failed(.registration(let failure)),
            let registration
        ) where isExpectedRegistrationFailure(
            failure,
            registration: registration
        ):
            return .noChange

        case (
            .failed(.approvalNavigation(.serviceUnavailable)),
            .serviceUnavailable
        ):
            return .noChange

        default:
            return .invalidCompletion
        }
    }

    package static func unregistrationDecision(
        _ view: HostAgentBackgroundUnregistrationUXView
    ) -> HostAgentBackgroundProductRoutingDecision {
        switch (view.phase, view.registration) {
        case (.unregistered, .notRegistered):
            return .disable

        case (.cancelled, nil):
            return .noChange

        case (.failed(.mutation(.serviceUnavailable)), .serviceUnavailable),
             (.failed(.mutation(.unregistrationNotEffective)), .enabled),
             (
                 .failed(.mutation(.unregistrationNotEffective)),
                 .requiresApproval
             ):
            return .noChange

        default:
            return .invalidCompletion
        }
    }

    private static func isExpectedRegistrationFailure(
        _ failure: HostAgentBackgroundRegistrationMutationFailure,
        registration: HostAgentBackgroundRegistrationStatus?
    ) -> Bool {
        switch (failure, registration) {
        case (.invalidLaunchAgent, nil),
             (.invalidApplication, nil),
             (.invalidCodeSignature, nil),
             (.distributionNotarizationRequired, nil),
             (.registrationNotEffective, .notRegistered),
             (.serviceUnavailable, .serviceUnavailable):
            return true
        default:
            return false
        }
    }
}
