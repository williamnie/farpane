import Foundation

/// Product command capability token. It binds an App activation epoch and
/// coherent projection generation to one reconnect-session route.
package struct HostAgentBackgroundCommandRoute: Equatable, Sendable {
    package let activationEpoch: UInt64
    package let projectionGeneration: UInt64
    package let reconnectRoute: HostAgentXPCReconnectCommandRoute

    package init(
        activationEpoch: UInt64,
        projectionGeneration: UInt64,
        reconnectRoute: HostAgentXPCReconnectCommandRoute
    ) {
        self.activationEpoch = activationEpoch
        self.projectionGeneration = projectionGeneration
        self.reconnectRoute = reconnectRoute
    }
}

package enum HostAgentBackgroundCommandAvailability:
    Equatable,
    Sendable
{
    case unavailable
    case available(
        route: HostAgentBackgroundCommandRoute,
        state: HostAgentXPCCommandIntentOwnerState
    )
}
