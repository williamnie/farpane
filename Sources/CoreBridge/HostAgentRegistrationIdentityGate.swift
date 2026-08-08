import Foundation

package enum HostAgentRegistrationIdentityStatus: Equatable, Sendable {
    case invalidLaunchAgent
    case invalidApplication
    case invalidCodeSignature
    case localDevelopmentEligible(buildIdentifier: String)
    case distributionNotarizationRequired(buildIdentifier: String)
}

/// Composes the immutable plist, bundle and code-signature gates without
/// performing registration. Eligibility here is identity-only: lifecycle,
/// explicit user intent and ServiceManagement state remain separate gates.
package enum HostAgentRegistrationIdentityGate {
    package static func assessMainBundle()
        -> HostAgentRegistrationIdentityStatus
    {
        let launchAgentPlistData: Data
        do {
            launchAgentPlistData = try HostAgentLaunchAgentAssetReader
                .readMainBundle()
        } catch {
            return .invalidLaunchAgent
        }

        return assess(
            launchAgentPlistData: launchAgentPlistData,
            inspectBundle: {
                try HostAgentRegistrationBundlePreflight.inspectMainBundle()
            },
            inspectCodeSignature: {
                try HostAgentRegistrationCodeSignaturePreflight
                    .inspectValidatedBundle(at: Bundle.main.bundleURL)
            }
        )
    }

    package static func assess(
        launchAgentPlistData: Data,
        inspectBundle: () throws -> HostAgentRegistrationBundleIdentity,
        inspectCodeSignature: () throws
            -> HostAgentRegistrationCodeSignatureEvidence
    ) -> HostAgentRegistrationIdentityStatus {
        do {
            try HostAgentLaunchAgentPlistPreflight.validate(
                launchAgentPlistData
            )
        } catch {
            return .invalidLaunchAgent
        }

        let bundleIdentity: HostAgentRegistrationBundleIdentity
        do {
            bundleIdentity = try inspectBundle()
        } catch {
            return .invalidApplication
        }

        let signature: HostAgentRegistrationCodeSignatureEvidence
        do {
            signature = try inspectCodeSignature()
        } catch {
            return .invalidCodeSignature
        }
        guard signature.signingIdentifier
            == HostAgentRegistrationCodeSignaturePreflight
                .expectedSigningIdentifier,
            signature.teamIdentifier
                == HostAgentRegistrationCodeSignaturePreflight
                    .expectedTeamIdentifier
        else {
            return .invalidCodeSignature
        }

        switch signature.channel {
        case .development:
            return .localDevelopmentEligible(
                buildIdentifier: bundleIdentity.buildIdentifier
            )
        case .developerID:
            return .distributionNotarizationRequired(
                buildIdentifier: bundleIdentity.buildIdentifier
            )
        }
    }
}
