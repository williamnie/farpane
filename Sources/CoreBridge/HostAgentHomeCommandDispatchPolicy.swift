/// Executes one already-validated Home command route through exactly one
/// injected owner operation. A rejected background operation is never retried
/// through the legacy operation.
package enum HostAgentHomeCommandDispatchPolicy {
    package typealias PerformLegacy = (
        _ action: HostAgentBackgroundHomeCommandAction,
        _ connectionID: String
    ) -> Bool
    package typealias SubmitBackground = (
        _ action: HostAgentBackgroundHomeCommandAction
    ) -> Bool
    package typealias RetryBackground = (
        _ action: HostAgentBackgroundHomeCommandAction
    ) -> Bool

    @discardableResult
    package static func dispatch(
        route: HostAgentHomeCommandRoute,
        performLegacy: PerformLegacy,
        submitBackground: SubmitBackground,
        retryBackground: RetryBackground
    ) -> Bool {
        switch route {
        case .none:
            return false
        case .legacy(let action, let connectionID):
            return performLegacy(action, connectionID)
        case .background(let action):
            return submitBackground(action)
        case .backgroundRetry(let action):
            return retryBackground(action)
        }
    }
}
