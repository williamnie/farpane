package struct HostAgentBackgroundHomeCommandReadOnlyPresentation:
    Equatable,
    Sendable
{
    package static let unavailable = Self(
        activeAction: nil,
        availableActions: [],
        retryAction: nil,
        statusText: "",
        errorText: "",
        canRetry: false
    )

    package let activeAction: HostAgentBackgroundHomeCommandAction?
    package let availableActions:
        [HostAgentBackgroundHomeCommandAction]
    package let retryAction: HostAgentBackgroundHomeCommandAction?
    package let statusText: String
    package let errorText: String
    package let canRetry: Bool
}

/// Read-only product projection for an App-owned command presentation owner.
/// It carries exact control eligibility but no command callback. Every click
/// still crosses the separate owner-aware Home routing boundary.
package enum HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy {
    package static func presentation(
        _ view: HostAgentBackgroundHomeCommandPresentationView?,
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?
    ) -> HostAgentBackgroundHomeCommandReadOnlyPresentation {
        guard let view else { return .unavailable }
        if let failure = view.failure {
            return HostAgentBackgroundHomeCommandReadOnlyPresentation(
                activeAction: nil,
                availableActions: [],
                retryAction: nil,
                statusText: "",
                errorText: failureText(failure),
                canRetry: false
            )
        }
        if let route = view.command.route {
            guard routeIsCoherent(
                route,
                phase: phase,
                projection: projection
            ) else { return .unavailable }
        }

        let result = view.result
        let availableActions:
            [HostAgentBackgroundHomeCommandAction]
        if result == nil,
           !view.command.isBusy,
           !view.command.canRetry,
           view.command.activeAction == nil
        {
            availableActions = view.command.availableActions
        } else {
            availableActions = []
        }
        let retryAction: HostAgentBackgroundHomeCommandAction?
        if view.command.canRetry,
           !view.command.isBusy,
           view.command.availableActions.isEmpty,
           let activeAction = view.command.activeAction,
           let result,
           result.action == activeAction,
           result.isTerminal,
           result.canRetry
        {
            retryAction = activeAction
        } else {
            retryAction = nil
        }
        return HostAgentBackgroundHomeCommandReadOnlyPresentation(
            activeAction: view.command.isBusy
                ? view.command.activeAction
                : nil,
            availableActions: availableActions,
            retryAction: retryAction,
            statusText: firstNonempty(
                result?.statusText,
                view.command.statusText
            ),
            errorText: firstNonempty(
                result?.errorText,
                view.command.errorText
            ),
            canRetry: retryAction != nil
        )
    }

    private static func routeIsCoherent(
        _ route: HostAgentBackgroundCommandRoute,
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?
    ) -> Bool {
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
              case .available(let available) = projection.phase
        else { return false }
        return available.peerIdentity
            == route.reconnectRoute.peerIdentity
    }

    private static func firstNonempty(
        _ preferred: String?,
        _ fallback: String
    ) -> String {
        if let preferred, !preferred.isEmpty { return preferred }
        return fallback
    }

    private static func failureText(
        _ failure: HostAgentBackgroundHomeCommandPresentationFailure
    ) -> String {
        switch failure {
        case .submissionRejected:
            return "后台未接收操作；请根据最新状态重试。"
        case .retryRejected:
            return "后台未接收重试；请根据最新状态重试。"
        case .invalidResult:
            return "后台命令状态不一致；已暂停当前操作。"
        case .generationExhausted:
            return "后台命令状态计数已耗尽；请重新启动 FarPane。"
        }
    }
}
