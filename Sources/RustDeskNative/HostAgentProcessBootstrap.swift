import CoreBridge

/// Exact product composition for a future pre-AppKit HostAgent dispatch. It
/// returns a stable process exit code but deliberately does not call `exit`;
/// the executable entry remains fail-closed until the next explicit step.
enum HostAgentProcessBootstrap {
    static func run() -> Int32 {
        HostAgentProcessBootstrapOrchestrator.run(
            assess: {
                HostAgentProcessEntryPreflight.assessMainProcess()
            },
            run: { eligibility in
                HostAgentProcessProductEntry.run(eligibility: eligibility)
            },
            report: { result in
                HostAgentProcessTerminalReporter.report(result)
            }
        )
    }
}
