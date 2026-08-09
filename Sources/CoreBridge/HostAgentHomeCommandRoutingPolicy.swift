package enum HostAgentHomeCommandOwner: Equatable, Sendable {
    case unavailable
    case legacy
    case background
}

package struct HostAgentHomeCommandVisibleTargets: Equatable, Sendable {
    package let approvalConnectionID: String?
    package let sessionConnectionID: String?
    package let enabledActions:
        [HostAgentBackgroundHomeCommandAction]

    package init(
        approvalConnectionID: String?,
        sessionConnectionID: String?,
        enabledActions: [HostAgentBackgroundHomeCommandAction]
    ) {
        self.approvalConnectionID = approvalConnectionID
        self.sessionConnectionID = sessionConnectionID
        self.enabledActions = enabledActions
    }
}

package enum HostAgentHomeCommandRequest: Equatable, Sendable {
    case perform(
        action: HostAgentBackgroundHomeCommandAction,
        connectionID: String
    )
    case retry(connectionID: String)
}

package enum HostAgentHomeCommandRoute: Equatable, Sendable {
    case none
    case legacy(
        action: HostAgentBackgroundHomeCommandAction,
        connectionID: String
    )
    case background(action: HostAgentBackgroundHomeCommandAction)
    case backgroundRetry(action: HostAgentBackgroundHomeCommandAction)
}

/// Pure owner-aware routing policy for future Home command callbacks. It does
/// not call either command owner. In particular, an invalid background route
/// is terminal `.none` and can never fall through to the legacy Host.
package enum HostAgentHomeCommandRoutingPolicy {
    package static func route(
        request: HostAgentHomeCommandRequest,
        owner: HostAgentHomeCommandOwner,
        visibleTargets: HostAgentHomeCommandVisibleTargets,
        legacyCommandsAvailable: Bool,
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?,
        commandView: HostAgentBackgroundHomeCommandPresentationView?
    ) -> HostAgentHomeCommandRoute {
        switch owner {
        case .unavailable:
            return .none
        case .legacy:
            return legacyRoute(
                request: request,
                visibleTargets: visibleTargets,
                commandsAvailable: legacyCommandsAvailable
            )
        case .background:
            return backgroundRoute(
                request: request,
                visibleTargets: visibleTargets,
                phase: phase,
                projection: projection,
                commandView: commandView
            )
        }
    }

    private static func legacyRoute(
        request: HostAgentHomeCommandRequest,
        visibleTargets: HostAgentHomeCommandVisibleTargets,
        commandsAvailable: Bool
    ) -> HostAgentHomeCommandRoute {
        guard commandsAvailable,
              case .perform(let action, let connectionID) = request,
              visibleTargets.enabledActions.contains(action),
              !connectionID.isEmpty,
              visibleConnectionID(
                for: action,
                targets: visibleTargets
              ) == connectionID
        else { return .none }
        return .legacy(action: action, connectionID: connectionID)
    }

    private static func backgroundRoute(
        request: HostAgentHomeCommandRequest,
        visibleTargets: HostAgentHomeCommandVisibleTargets,
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?,
        commandView: HostAgentBackgroundHomeCommandPresentationView?
    ) -> HostAgentHomeCommandRoute {
        guard let commandView,
              commandView.failure == nil,
              let route = commandView.command.route,
              let payload = coherentPayload(
                route: route,
                phase: phase,
                projection: projection
              )
        else { return .none }

        switch request {
        case .perform(let action, let connectionID):
            guard commandView.result == nil,
                  !commandView.command.isBusy,
                  !commandView.command.canRetry,
                  commandView.command.activeAction == nil,
                  commandView.command.availableActions.contains(action),
                  exactVisibleTarget(
                    action: action,
                    connectionID: connectionID,
                    visibleTargets: visibleTargets,
                    payload: payload
                  )
            else { return .none }
            return .background(action: action)

        case .retry(let connectionID):
            guard let action = commandView.command.activeAction,
                  commandView.command.availableActions.isEmpty,
                  !commandView.command.isBusy,
                  commandView.command.canRetry,
                  let result = commandView.result,
                  result.action == action,
                  result.isTerminal,
                  result.canRetry,
                  exactVisibleTarget(
                    action: action,
                    connectionID: connectionID,
                    visibleTargets: visibleTargets,
                    payload: payload
                  )
            else { return .none }
            return .backgroundRetry(action: action)
        }
    }

    private static func coherentPayload(
        route: HostAgentBackgroundCommandRoute,
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?
    ) -> HostAgentXPCWireSnapshotPayload? {
        guard case .monitoring(let epoch, let readiness) = phase,
              epoch == route.activationEpoch,
              readiness.failure == nil,
              readiness.registration == .enabled,
              let projection,
              projection.generation
                == readiness.runtime.projectionGeneration,
              HostAgentBackgroundRuntimeEvidence(projection: projection)
                == readiness.runtime,
              projection.generation == route.projectionGeneration,
              case .available(let available) = projection.phase,
              available.peerIdentity
                == route.reconnectRoute.peerIdentity
        else { return nil }
        return available.payload
    }

    private static func exactVisibleTarget(
        action: HostAgentBackgroundHomeCommandAction,
        connectionID: String,
        visibleTargets: HostAgentHomeCommandVisibleTargets,
        payload: HostAgentXPCWireSnapshotPayload
    ) -> Bool {
        guard !connectionID.isEmpty,
              visibleTargets.enabledActions.contains(action),
              visibleConnectionID(
                for: action,
                targets: visibleTargets
              ) == connectionID
        else { return false }
        return projectedConnectionID(for: action, payload: payload)
            == connectionID
    }

    private static func visibleConnectionID(
        for action: HostAgentBackgroundHomeCommandAction,
        targets: HostAgentHomeCommandVisibleTargets
    ) -> String? {
        switch action {
        case .approveIncoming, .rejectIncoming:
            return targets.approvalConnectionID
        case .disableKeyboardAndMouse, .disableClipboard,
             .disableSystemAudio, .disconnect:
            return targets.sessionConnectionID
        }
    }

    private static func projectedConnectionID(
        for action: HostAgentBackgroundHomeCommandAction,
        payload: HostAgentXPCWireSnapshotPayload
    ) -> String? {
        switch action {
        case .approveIncoming, .rejectIncoming:
            return payload.pendingApproval?.connectionID
        case .disableKeyboardAndMouse, .disableClipboard,
             .disableSystemAudio, .disconnect:
            return payload.activeSession?.connectionID
        }
    }
}
