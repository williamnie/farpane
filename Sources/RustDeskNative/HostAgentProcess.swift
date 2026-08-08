import CoreBridge
import Foundation

/// Complete process-lifetime composition for the future `--host-agent` entry.
/// The caller must provide the authoritative Host event consumer; this type
/// deliberately neither prints diagnostics nor exits the process.
enum HostAgentProcess {
    static func run(
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) -> HostAgentProcessRunResult {
        HostAgentProcessRunner.run(
            installTerminationIngress: {
                try HostAgentProcessSignalController()
            },
            startRuntime: {
                HostAgentProcessStartup.prepare(
                    onEvent: onEvent
                )
            },
            bindTermination: { controller, lifetime in
                controller.bind(lifetime: lifetime)
            },
            requestTermination: { lifetime, reason in
                lifetime.requestTermination(reason: reason)
            },
            waitUntilTerminated: { lifetime in
                lifetime.waitUntilTerminated()
            },
            cancelTerminationIngress: { controller in
                controller.cancel()
            }
        )
    }
}
