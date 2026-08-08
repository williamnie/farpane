/// Resolves one entry assessment, optionally runs one eligible HostAgent
/// lifetime, then reports the resulting terminal value exactly once.
/// Reporting remains injected so this layer performs no process I/O or exit.
package enum HostAgentProcessBootstrapOrchestrator {
    package static func run(
        assess: () -> HostAgentProcessEntryAssessment,
        run: (HostAgentProcessEntryEligibility) -> HostAgentProcessRunResult,
        report: (HostAgentProcessTerminalResult) -> Int32
    ) -> Int32 {
        let terminalResult = HostAgentProcessEntryOrchestrator.resolve(
            assess: assess,
            run: run
        )
        return report(terminalResult)
    }
}
