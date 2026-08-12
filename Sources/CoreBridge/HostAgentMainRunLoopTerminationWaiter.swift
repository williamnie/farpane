import Foundation

/// Waits for HostAgent termination while allowing macOS main-queue work to
/// execute. RustDesk dispatches macOS input injection to the main queue, so a
/// blocking condition wait on the process main thread would disable control.
public enum HostAgentMainRunLoopTerminationWaiter {
    public static func wait(
        pollInterval: TimeInterval = 0.05,
        terminationOutcome: () -> HostAgentProcessTerminationOutcome?
    ) -> HostAgentProcessTerminationOutcome {
        precondition(Thread.isMainThread)
        precondition(pollInterval > 0)

        while true {
            if let outcome = terminationOutcome() { return outcome }
            _ = RunLoop.current.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: pollInterval)
            )
        }
    }
}
