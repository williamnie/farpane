extension HostAgentProcessEntryFailure {
    package var exitCode: Int32 {
        switch self {
        case .invalidInvocation:
            return 64 // EX_USAGE
        case .invalidLaunchAgent, .invalidApplication:
            return 78 // EX_CONFIG
        case .invalidCodeSignature, .distributionNotarizationRequired:
            return 77 // EX_NOPERM
        }
    }

    package var diagnostic: String {
        switch self {
        case .invalidInvocation:
            return "FarPane HostAgent invocation is invalid."
        case .invalidLaunchAgent:
            return "FarPane HostAgent launch configuration is invalid."
        case .invalidApplication:
            return "FarPane HostAgent application identity is invalid."
        case .invalidCodeSignature:
            return "FarPane HostAgent code signature is invalid."
        case .distributionNotarizationRequired:
            return "FarPane HostAgent notarization evidence is unavailable."
        }
    }
}

/// Resolves the read-only product entry assessment into one sanitized process
/// result. A rejection can never reach the runner, while eligible evidence is
/// checked again at the trust boundary and consumed exactly once.
package enum HostAgentProcessEntryOrchestrator {
    package static func resolve(
        assess: () -> HostAgentProcessEntryAssessment,
        run: (HostAgentProcessEntryEligibility) -> HostAgentProcessRunResult
    ) -> HostAgentProcessTerminalResult {
        switch assess() {
        case .rejected(let failure):
            return .entryRejected(failure)
        case .eligible(let eligibility):
            guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
                eligibility.buildIdentifier
            ) else {
                return .entryRejected(.invalidApplication)
            }

            switch eligibility.signingChannel {
            case .localDevelopment:
                return .process(run(eligibility))
            }
        }
    }
}
