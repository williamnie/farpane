import Foundation

package enum HostAgentBackgroundHomeCommandAction:
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case approveIncoming
    case rejectIncoming
    case disableKeyboardAndMouse
    case disableClipboardRead
    case disableClipboardWrite
    case disableClipboard
    case disableSystemAudio
    case disconnect
}

package enum HostAgentBackgroundHomeCommandTone: Equatable, Sendable {
    case neutral
    case success
    case warning
    case error
}

package struct HostAgentBackgroundHomeCommandSubmission:
    Equatable,
    Sendable
{
    package let route: HostAgentBackgroundCommandRoute
    package let intent: HostAgentXPCCommandIntent
}

package struct HostAgentBackgroundHomeCommandPresentation:
    Equatable,
    Sendable
{
    package static let unavailable = Self(
        route: nil,
        availableActions: [],
        activeAction: nil,
        statusText: "",
        errorText: "",
        isBusy: false,
        canRetry: false,
        actionTargets: [],
        retryIntent: nil
    )

    package let route: HostAgentBackgroundCommandRoute?
    package let availableActions: [HostAgentBackgroundHomeCommandAction]
    package let activeAction: HostAgentBackgroundHomeCommandAction?
    package let statusText: String
    package let errorText: String
    package let isBusy: Bool
    package let canRetry: Bool

    fileprivate let actionTargets:
        [HostAgentBackgroundHomeCommandActionTarget]
    fileprivate let retryIntent: HostAgentXPCCommandIntent?

    fileprivate init(
        route: HostAgentBackgroundCommandRoute?,
        availableActions: [HostAgentBackgroundHomeCommandAction],
        activeAction: HostAgentBackgroundHomeCommandAction?,
        statusText: String,
        errorText: String,
        isBusy: Bool,
        canRetry: Bool,
        actionTargets: [HostAgentBackgroundHomeCommandActionTarget],
        retryIntent: HostAgentXPCCommandIntent?
    ) {
        self.route = route
        self.availableActions = availableActions
        self.activeAction = activeAction
        self.statusText = statusText
        self.errorText = errorText
        self.isBusy = isBusy
        self.canRetry = canRetry
        self.actionTargets = actionTargets
        self.retryIntent = retryIntent
    }
}

package struct HostAgentBackgroundHomeCommandResultPresentation:
    Equatable,
    Sendable
{
    package let action: HostAgentBackgroundHomeCommandAction
    package let statusText: String
    package let errorText: String
    package let tone: HostAgentBackgroundHomeCommandTone
    package let isTerminal: Bool
    package let canRetry: Bool
}

private struct HostAgentBackgroundHomeCommandActionTarget:
    Equatable,
    Sendable
{
    let action: HostAgentBackgroundHomeCommandAction
    let connectionID: String
}

/// Pure Home policy for the background command route. It independently
/// rechecks activation/projection coherence before exposing any action and
/// never calls the activation owner, AppKit or the legacy in-process Host.
package enum HostAgentBackgroundHomeCommandPolicy {
    package typealias CommandIDFactory = () -> String

    package static func presentation(
        phase: HostAgentBackgroundActivationPhase?,
        projection: HostAgentBackgroundProjectionView?,
        availability: HostAgentBackgroundCommandAvailability
    ) -> HostAgentBackgroundHomeCommandPresentation {
        guard case .monitoring(let epoch, let readiness) = phase,
              readiness.failure == nil,
              readiness.registration == .enabled,
              let projection,
              projection.generation
                == readiness.runtime.projectionGeneration,
              HostAgentBackgroundRuntimeEvidence(projection: projection)
                == readiness.runtime,
              case .available(let availableProjection) = projection.phase,
              case .available(let route, let state) = availability,
              route.activationEpoch == epoch,
              route.projectionGeneration == projection.generation,
              route.reconnectRoute.peerIdentity
                == availableProjection.peerIdentity
        else { return .unavailable }

        switch state {
        case .idle:
            let targets = actionTargets(
                for: availableProjection.payload
            )
            return HostAgentBackgroundHomeCommandPresentation(
                route: route,
                availableActions: targets.map(\.action),
                activeAction: nil,
                statusText: "",
                errorText: "",
                isBusy: false,
                canRetry: false,
                actionTargets: targets,
                retryIntent: nil
            )
        case .pausing(let intent), .awaitingAcceptance(let intent):
            return intentPresentation(
                intent,
                route: route,
                projection: availableProjection,
                statusText: "正在提交%@…",
                errorText: "",
                isBusy: true,
                canRetry: false
            )
        case .awaitingResult(let intent):
            return intentPresentation(
                intent,
                route: route,
                projection: availableProjection,
                statusText: "%@已排队，等待后台确认…",
                errorText: "",
                isBusy: true,
                canRetry: false
            )
        case .retryable(let intent):
            return intentPresentation(
                intent,
                route: route,
                projection: availableProjection,
                statusText: "",
                errorText: "无法确认%@结果；可重试同一操作。",
                isBusy: false,
                canRetry: true
            )
        case .invalidated, .cancelled:
            return .unavailable
        }
    }

    /// Creates one new submission only from an idle action target. Product
    /// callers use the UUID wrapper below; tests may inject a deterministic
    /// factory. Retry never enters this path and therefore cannot replace the
    /// retained command ID.
    package static func submission(
        action: HostAgentBackgroundHomeCommandAction,
        presentation: HostAgentBackgroundHomeCommandPresentation,
        makeCommandID: CommandIDFactory
    ) -> HostAgentBackgroundHomeCommandSubmission? {
        guard let route = presentation.route,
              !presentation.isBusy,
              !presentation.canRetry,
              presentation.activeAction == nil,
              presentation.availableActions.contains(action),
              let target = presentation.actionTargets.first(where: {
                  $0.action == action
              })
        else { return nil }
        let commandID = makeCommandID()
        guard HostAgentXPCWireHandshakeContract.validIdentifier(commandID)
        else { return nil }
        return HostAgentBackgroundHomeCommandSubmission(
            route: route,
            intent: HostAgentXPCCommandIntent(
                commandID: commandID,
                name: commandName(for: action),
                connectionID: target.connectionID
            )
        )
    }

    package static func productSubmission(
        action: HostAgentBackgroundHomeCommandAction,
        presentation: HostAgentBackgroundHomeCommandPresentation
    ) -> HostAgentBackgroundHomeCommandSubmission? {
        submission(action: action, presentation: presentation) {
            UUID().uuidString.lowercased()
        }
    }

    package static func retryRoute(
        presentation: HostAgentBackgroundHomeCommandPresentation
    ) -> HostAgentBackgroundCommandRoute? {
        guard presentation.canRetry,
              presentation.retryIntent != nil,
              presentation.availableActions.isEmpty,
              !presentation.isBusy
        else { return nil }
        return presentation.route
    }

    package static func resultPresentation(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        submission: HostAgentBackgroundHomeCommandSubmission
    ) -> HostAgentBackgroundHomeCommandResultPresentation? {
        let intent = submission.intent
        let peerIdentity = submission.route.reconnectRoute.peerIdentity
        guard HostAgentXPCWireHandshakeContract.validIdentifier(
                intent.commandID
              ),
              intent.connectionID.hasPrefix(
                "\(peerIdentity.hostInstanceID):"
              ),
              let action = action(for: intent.name)
        else { return nil }
        let title = actionTitle(action)

        switch result {
        case .accepted(let accepted):
            guard accepted.commandID == intent.commandID,
                  accepted.hostInstanceID == peerIdentity.hostInstanceID,
                  accepted.agentBootID == peerIdentity.agentBootID
            else { return nil }
            return makeResult(
                action: action,
                status: "\(title)已排队，等待后台确认…",
                tone: .neutral,
                isTerminal: false
            )
        case .completed(let completed):
            guard completed.commandID == intent.commandID else { return nil }
            switch completed.status {
            case .ok:
                return makeResult(
                    action: action,
                    status: "\(title)已完成。",
                    tone: .success
                )
            case .rejected:
                return makeResult(
                    action: action,
                    error: "后台拒绝了\(title)请求。",
                    tone: .warning
                )
            case .error:
                return makeResult(
                    action: action,
                    error: "后台未能完成\(title)。",
                    tone: .error
                )
            case .unknownCommand:
                return makeResult(
                    action: action,
                    error: "后台版本不支持\(title)。",
                    tone: .error
                )
            }
        case .resultUnknown:
            return makeResult(
                action: action,
                error: "连接中断，无法确认\(title)结果；可重试同一操作。",
                tone: .warning,
                canRetry: true
            )
        case .resultTimedOut:
            return makeResult(
                action: action,
                error: "等待\(title)结果超时；可重试同一操作。",
                tone: .warning,
                canRetry: true
            )
        case .invalidRequest:
            return makeResult(
                action: action,
                error: "当前操作不再有效，请根据最新状态重试。",
                tone: .warning
            )
        case .invalidResponse:
            return makeResult(
                action: action,
                error: "后台返回了无法验证的操作结果。",
                tone: .error
            )
        case .disconnected:
            return makeResult(
                action: action,
                error: "后台连接已断开，无法确认操作是否提交。",
                tone: .error
            )
        case .acceptanceTimedOut:
            return makeResult(
                action: action,
                error: "后台未在限定时间内接收操作。",
                tone: .error
            )
        case .cancelled:
            return makeResult(
                action: action,
                error: "操作已取消。",
                tone: .warning
            )
        case .invalidState:
            return makeResult(
                action: action,
                error: "后台命令通道状态不可用。",
                tone: .error
            )
        }
    }

    private static func intentPresentation(
        _ intent: HostAgentXPCCommandIntent,
        route: HostAgentBackgroundCommandRoute,
        projection: HostAgentBackgroundProjection,
        statusText: String,
        errorText: String,
        isBusy: Bool,
        canRetry: Bool
    ) -> HostAgentBackgroundHomeCommandPresentation {
        guard HostAgentXPCWireHandshakeContract.validIdentifier(
                intent.commandID
              ),
              let action = action(for: intent.name),
              HostAgentBackgroundSessionCommandPolicy.allows(
                intent,
                payload: projection.payload
              ),
              connectionID(
                for: action,
                payload: projection.payload
              ) == intent.connectionID
        else { return .unavailable }
        let title = actionTitle(action)
        return HostAgentBackgroundHomeCommandPresentation(
            route: route,
            availableActions: [],
            activeAction: action,
            statusText: String(format: statusText, title),
            errorText: String(format: errorText, title),
            isBusy: isBusy,
            canRetry: canRetry,
            actionTargets: [],
            retryIntent: canRetry ? intent : nil
        )
    }

    private static func actionTargets(
        for payload: HostAgentXPCWireSnapshotPayload
    ) -> [HostAgentBackgroundHomeCommandActionTarget] {
        if payload.sessionAvailability == .limited {
            guard payload.sessionUnavailableReason == .sessionUnavailable,
                  let session = payload.activeSession
            else { return [] }
            return [.init(
                action: .disconnect,
                connectionID: session.connectionID
            )]
        }
        var targets: [HostAgentBackgroundHomeCommandActionTarget] = []
        if let pending = payload.pendingApproval {
            targets.append(.init(
                action: .approveIncoming,
                connectionID: pending.connectionID
            ))
            targets.append(.init(
                action: .rejectIncoming,
                connectionID: pending.connectionID
            ))
        }
        if let session = payload.activeSession {
            let capabilities = Set(session.activeCapabilities)
            if HostSessionRevocableCapability.keyboardAndMouse
                .snapshotCapabilityNames.isSubset(of: capabilities)
            {
                targets.append(.init(
                    action: .disableKeyboardAndMouse,
                    connectionID: session.connectionID
                ))
            }
            if capabilities.contains("readClipboard") {
                targets.append(.init(
                    action: .disableClipboardRead,
                    connectionID: session.connectionID
                ))
            }
            if capabilities.contains("writeClipboard") {
                targets.append(.init(
                    action: .disableClipboardWrite,
                    connectionID: session.connectionID
                ))
            }
            if HostSessionRevocableCapability.systemAudio
                .snapshotCapabilityNames.isSubset(of: capabilities)
            {
                targets.append(.init(
                    action: .disableSystemAudio,
                    connectionID: session.connectionID
                ))
            }
            targets.append(.init(
                action: .disconnect,
                connectionID: session.connectionID
            ))
        }
        return targets
    }

    private static func connectionID(
        for action: HostAgentBackgroundHomeCommandAction,
        payload: HostAgentXPCWireSnapshotPayload
    ) -> String? {
        switch action {
        case .approveIncoming, .rejectIncoming:
            return payload.pendingApproval?.connectionID
        case .disableKeyboardAndMouse, .disableClipboardRead,
             .disableClipboardWrite, .disableClipboard,
             .disableSystemAudio, .disconnect:
            return payload.activeSession?.connectionID
        }
    }

    private static func action(
        for name: HostAgentXPCWireCommandName
    ) -> HostAgentBackgroundHomeCommandAction? {
        switch name {
        case .approveIncoming: return .approveIncoming
        case .rejectIncoming: return .rejectIncoming
        case .disableInputForActiveSession:
            return .disableKeyboardAndMouse
        case .disableClipboardReadForActiveSession:
            return .disableClipboardRead
        case .disableClipboardWriteForActiveSession:
            return .disableClipboardWrite
        case .disableClipboardForActiveSession:
            return .disableClipboard
        case .disableAudioForActiveSession:
            return .disableSystemAudio
        case .disconnectSession: return .disconnect
        }
    }

    private static func commandName(
        for action: HostAgentBackgroundHomeCommandAction
    ) -> HostAgentXPCWireCommandName {
        switch action {
        case .approveIncoming: return .approveIncoming
        case .rejectIncoming: return .rejectIncoming
        case .disableKeyboardAndMouse:
            return .disableInputForActiveSession
        case .disableClipboardRead:
            return .disableClipboardReadForActiveSession
        case .disableClipboardWrite:
            return .disableClipboardWriteForActiveSession
        case .disableClipboard:
            return .disableClipboardForActiveSession
        case .disableSystemAudio:
            return .disableAudioForActiveSession
        case .disconnect: return .disconnectSession
        }
    }

    private static func actionTitle(
        _ action: HostAgentBackgroundHomeCommandAction
    ) -> String {
        switch action {
        case .approveIncoming: return "允许连接"
        case .rejectIncoming: return "拒绝连接"
        case .disableKeyboardAndMouse: return "停止键鼠控制"
        case .disableClipboardRead: return "停止远端读取剪贴板"
        case .disableClipboardWrite: return "停止远端写入剪贴板"
        case .disableClipboard: return "停止剪贴板"
        case .disableSystemAudio: return "停止系统音频"
        case .disconnect: return "断开连接"
        }
    }

    private static func makeResult(
        action: HostAgentBackgroundHomeCommandAction,
        status: String = "",
        error: String = "",
        tone: HostAgentBackgroundHomeCommandTone,
        isTerminal: Bool = true,
        canRetry: Bool = false
    ) -> HostAgentBackgroundHomeCommandResultPresentation {
        HostAgentBackgroundHomeCommandResultPresentation(
            action: action,
            statusText: status,
            errorText: error,
            tone: tone,
            isTerminal: isTerminal,
            canRetry: canRetry
        )
    }
}
