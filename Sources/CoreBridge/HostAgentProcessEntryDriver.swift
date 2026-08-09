/// Owns the mutable authorities for exactly one HostAgent boot. Keeping
/// them behind one owner prevents a future entry point from accidentally
/// mixing state across process attempts.
package final class HostAgentProcessEntryStateOwner: @unchecked Sendable {
    package let eventState: HostAgentEventState
    package let snapshotState: HostAgentSnapshotState
    package let mediaState: HostAgentMediaControlState
    package let concurrencyState: HostAgentConcurrencyObservationState

    package init() throws {
        eventState = try HostAgentEventState()
        snapshotState = HostAgentSnapshotState()
        mediaState = HostAgentMediaControlState()
        concurrencyState = HostAgentConcurrencyObservationState()
    }
}

/// Constructs one process state owner and hands the exact entry eligibility to
/// one runner invocation. Construction errors and forged typed evidence are
/// reduced to the existing sanitized internal process failure.
package enum HostAgentProcessEntryDriver {
    package static func run(
        eligibility: HostAgentProcessEntryEligibility,
        makeStateOwner: () throws -> HostAgentProcessEntryStateOwner = {
            try HostAgentProcessEntryStateOwner()
        },
        run: (
            HostAgentProcessEntryEligibility,
            HostAgentProcessEntryStateOwner
        ) -> HostAgentProcessRunResult
    ) -> HostAgentProcessRunResult {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
            eligibility.buildIdentifier
        ) else {
            return .internalFailure
        }

        switch eligibility.signingChannel {
        case .localDevelopment:
            break
        }

        do {
            let stateOwner = try makeStateOwner()
            return run(eligibility, stateOwner)
        } catch {
            return .internalFailure
        }
    }
}
