import Foundation

package enum HostAgentProcessEntrySigningChannel: Equatable, Sendable {
    case localDevelopment
}

package struct HostAgentProcessEntryEligibility: Equatable, Sendable {
    package let buildIdentifier: String
    package let signingChannel: HostAgentProcessEntrySigningChannel

    package init(
        buildIdentifier: String,
        signingChannel: HostAgentProcessEntrySigningChannel
    ) {
        self.buildIdentifier = buildIdentifier
        self.signingChannel = signingChannel
    }
}

package enum HostAgentProcessEntryFailure: Equatable, Sendable {
    case invalidInvocation
    case invalidLaunchAgent
    case invalidApplication
    case invalidCodeSignature
    case distributionNotarizationRequired
}

package enum HostAgentProcessEntryAssessment: Equatable, Sendable {
    case eligible(HostAgentProcessEntryEligibility)
    case rejected(HostAgentProcessEntryFailure)
}

/// Read-only gate for the future top-level HostAgent dispatch. It composes the
/// exact launchd invocation with the existing fixed plist, installed bundle and
/// Apple-issued signing evidence. It cannot start a runtime or mutate service
/// registration, and Developer ID remains closed until notarization is proven.
package enum HostAgentProcessEntryPreflight {
    private static let executableName = "RustDeskNative"
    private static let installedExecutable =
        "/Applications/FarPane.app/Contents/MacOS/RustDeskNative"
    private static let agentFlag = "--host-agent"

    package static func assessMainProcess()
        -> HostAgentProcessEntryAssessment
    {
        assess(
            arguments: CommandLine.arguments,
            assessIdentity: {
                HostAgentRegistrationIdentityGate.assessMainBundle()
            }
        )
    }

    package static func assess(
        arguments: [String],
        assessIdentity: () -> HostAgentRegistrationIdentityStatus
    ) -> HostAgentProcessEntryAssessment {
        guard validInvocation(arguments) else {
            return .rejected(.invalidInvocation)
        }

        switch assessIdentity() {
        case .invalidLaunchAgent:
            return .rejected(.invalidLaunchAgent)
        case .invalidApplication:
            return .rejected(.invalidApplication)
        case .invalidCodeSignature:
            return .rejected(.invalidCodeSignature)
        case .localDevelopmentEligible(let buildIdentifier):
            guard HostAgentRegistrationBundlePreflight
                .validBuildIdentifier(buildIdentifier)
            else {
                return .rejected(.invalidApplication)
            }
            return .eligible(HostAgentProcessEntryEligibility(
                buildIdentifier: buildIdentifier,
                signingChannel: .localDevelopment
            ))
        case .distributionNotarizationRequired(let buildIdentifier):
            guard HostAgentRegistrationBundlePreflight
                .validBuildIdentifier(buildIdentifier)
            else {
                return .rejected(.invalidApplication)
            }
            return .rejected(.distributionNotarizationRequired)
        }
    }

    private static func validInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count == 2,
              arguments[1] == agentFlag
        else {
            return false
        }
        return arguments[0] == executableName
            || arguments[0] == installedExecutable
    }
}
