import CoreBridge

/// Final product composition immediately below the still-disabled top-level
/// dispatch. It creates one boot state owner and consumes the exact build
/// eligibility that passed the entry identity gate.
enum HostAgentProcessProductEntry {
    static func run(
        eligibility: HostAgentProcessEntryEligibility
    ) -> HostAgentProcessRunResult {
        HostAgentProcessEntryDriver.run(
            eligibility: eligibility,
            run: { eligibility, stateOwner in
                HostAgentProcess.run(
                    expectedAgentBuildID: eligibility.buildIdentifier,
                    eventState: stateOwner.eventState,
                    snapshotState: stateOwner.snapshotState,
                    mediaState: stateOwner.mediaState,
                    concurrencyState: stateOwner.concurrencyState
                )
            }
        )
    }
}
