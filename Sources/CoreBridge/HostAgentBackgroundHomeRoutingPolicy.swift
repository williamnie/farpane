package enum HostAgentBackgroundHomeFlow: Equatable, Sendable {
    case registration
    case unregistration
}

package struct HostAgentBackgroundHomeControlState:
    Equatable,
    Sendable
{
    package let isOn: Bool
    package let isInteractive: Bool

    package init(isOn: Bool, isInteractive: Bool) {
        self.isOn = isOn
        self.isInteractive = isInteractive
    }
}

package enum HostAgentBackgroundHomeToggleRoute: Equatable, Sendable {
    case noAction
    case stopLegacyHost
    case beginRegistration
    case beginUnregistration
}

package enum HostAgentBackgroundHomeLaunchRoute: Equatable, Sendable {
    case preserveLegacyHost
    case observeBackground
    case quiesceLegacyThenObserveBackground
    case hold
}

/// Pure Home routing authority. Registration status and the complete legacy
/// migration assessment remain independent: a user request cannot be routed
/// to the opposite owner, and unknown or conflicting ownership is inert.
package enum HostAgentBackgroundHomeRoutingPolicy {
    package static func controlState(
        registration: HostAgentBackgroundRegistrationStatus,
        legacy: HostAgentLegacyHostMigrationAssessment,
        flow: HostAgentBackgroundHomeFlow?
    ) -> HostAgentBackgroundHomeControlState {
        let legacyIntentOn = legacyIntentIsOn(legacy)
        let isOn: Bool
        switch registration {
        case .enabled, .requiresApproval:
            isOn = true
        case .notRegistered:
            isOn = legacyIntentOn
        case .serviceUnavailable:
            // A replaced App can lose its ServiceManagement record while the
            // durable legacy preference remains enabled. Do not present that
            // stale preference as a running Host; an actually active legacy
            // runtime must still be stopped before registration is retried.
            isOn = legacyRuntimeIsOn(legacy)
        }

        guard flow == nil else {
            return HostAgentBackgroundHomeControlState(
                isOn: isOn,
                isInteractive: false
            )
        }

        let isInteractive: Bool
        switch legacy {
        case .failed:
            isInteractive = false
        case .eligible:
            isInteractive = true
        case .blocked:
            switch registration {
            case .notRegistered, .serviceUnavailable:
                isInteractive = true
            case .enabled, .requiresApproval:
                isInteractive = false
            }
        }
        return HostAgentBackgroundHomeControlState(
            isOn: isOn,
            isInteractive: isInteractive
        )
    }

    package static func toggleRoute(
        requestedEnabled: Bool,
        registration: HostAgentBackgroundRegistrationStatus,
        legacy: HostAgentLegacyHostMigrationAssessment,
        flow: HostAgentBackgroundHomeFlow?
    ) -> HostAgentBackgroundHomeToggleRoute {
        let control = controlState(
            registration: registration,
            legacy: legacy,
            flow: flow
        )
        guard control.isInteractive,
              control.isOn != requestedEnabled
        else { return .noAction }

        switch (requestedEnabled, registration) {
        case (true, .notRegistered), (true, .serviceUnavailable):
            return .beginRegistration
        case (false, .notRegistered) where legacyIntentIsOn(legacy):
            return .stopLegacyHost
        case (false, .serviceUnavailable) where legacyRuntimeIsOn(legacy):
            return .stopLegacyHost
        case (false, .enabled), (false, .requiresApproval):
            return .beginUnregistration
        case (true, .enabled), (true, .requiresApproval),
             (false, .serviceUnavailable), (false, .notRegistered):
            return .noAction
        }
    }

    package static func allowsClipboardPolicyChange(
        control: HostAgentBackgroundHomeControlState,
        viewerConnectionInProgress: Bool
    ) -> Bool {
        control.isInteractive
            && !control.isOn
            && !viewerConnectionInProgress
    }

    package static func allowsFileTransferPolicyChange(
        control: HostAgentBackgroundHomeControlState,
        viewerConnectionInProgress: Bool
    ) -> Bool {
        allowsClipboardPolicyChange(
            control: control,
            viewerConnectionInProgress: viewerConnectionInProgress
        )
    }

    package static func allowsAudioPolicyChange(
        control: HostAgentBackgroundHomeControlState,
        viewerConnectionInProgress: Bool,
        authorizationRequestInProgress: Bool
    ) -> Bool {
        allowsClipboardPolicyChange(
            control: control,
            viewerConnectionInProgress: viewerConnectionInProgress
        ) && !authorizationRequestInProgress
    }

    package static func allowsHostToggle(
        control: HostAgentBackgroundHomeControlState,
        bootstrapReady: Bool
    ) -> Bool {
        control.isInteractive && (control.isOn || bootstrapReady)
    }

    /// A configured product should enter its useful default state without
    /// requiring the user to toggle Host on after every explicit App quit.
    /// Registration remains a once-per-process attempt so a persistent
    /// system or signing failure cannot create an activation loop.
    package static func shouldAutomaticallyRegister(
        registration: HostAgentBackgroundRegistrationStatus,
        legacy: HostAgentLegacyHostMigrationAssessment,
        bootstrapReady: Bool,
        alreadyAttempted: Bool
    ) -> Bool {
        guard bootstrapReady,
              !alreadyAttempted,
              legacy == .eligible
        else { return false }
        switch registration {
        case .notRegistered, .serviceUnavailable:
            return true
        case .enabled, .requiresApproval:
            return false
        }
    }

    package static func launchRoute(
        registration: HostAgentBackgroundRegistrationStatus,
        legacy: HostAgentLegacyHostMigrationAssessment
    ) -> HostAgentBackgroundHomeLaunchRoute {
        if case .failed = legacy { return .hold }
        switch registration {
        case .serviceUnavailable:
            return .hold
        case .notRegistered:
            return legacyIntentIsOn(legacy)
                ? .preserveLegacyHost
                : .hold
        case .enabled, .requiresApproval:
            switch legacy {
            case .eligible:
                return .observeBackground
            case .blocked:
                return .quiesceLegacyThenObserveBackground
            case .failed:
                return .hold
            }
        }
    }

    private static func legacyIntentIsOn(
        _ assessment: HostAgentLegacyHostMigrationAssessment
    ) -> Bool {
        guard case .blocked(let blockers) = assessment else {
            return false
        }
        return blockers.contains(.preferenceEnabled)
            || blockers.contains(.runtimeActive)
    }

    private static func legacyRuntimeIsOn(
        _ assessment: HostAgentLegacyHostMigrationAssessment
    ) -> Bool {
        guard case .blocked(let blockers) = assessment else {
            return false
        }
        return blockers.contains(.runtimeActive)
    }
}
