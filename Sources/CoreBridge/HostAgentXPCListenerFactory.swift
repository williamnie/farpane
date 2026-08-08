import Foundation

/// Creates the future HostAgent Mach-service listener with the immutable
/// product signing gate installed before a delegate or interface can exist.
/// Activation remains owned by the eventual authenticated XPC runtime.
package enum HostAgentXPCListenerFactory {
    package static let machServiceName =
        HostAgentLaunchAgentPlistPreflight.label

    package static func makeListener() -> NSXPCListener {
        let listener = NSXPCListener(machServiceName: machServiceName)
        listener.setConnectionCodeSigningRequirement(
            HostAgentRegistrationCodeSignaturePreflight.productRequirement
        )
        return listener
    }
}
