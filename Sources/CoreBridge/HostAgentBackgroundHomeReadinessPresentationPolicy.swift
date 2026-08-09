package struct HostAgentBackgroundHomeReadinessPresentation:
    Equatable,
    Sendable
{
    package let isRunning: Bool
    package let isReady: Bool
    package let isBusy: Bool
    package let statusText: String
    package let errorText: String

    package init(
        isRunning: Bool,
        isReady: Bool,
        isBusy: Bool,
        statusText: String,
        errorText: String
    ) {
        self.isRunning = isRunning
        self.isReady = isReady
        self.isBusy = isBusy
        self.statusText = statusText
        self.errorText = errorText
    }
}

/// Bounded Home copy derived only from typed activation/readiness evidence.
/// A validated Agent snapshot may establish `isRunning`; only the complete
/// four-component H4.2a health tuple may establish `isReady`.
package enum HostAgentBackgroundHomeReadinessPresentationPolicy {
    package static func presentation(
        phase: HostAgentBackgroundActivationPhase?,
        registration: HostAgentBackgroundRegistrationStatus
    ) -> HostAgentBackgroundHomeReadinessPresentation {
        guard let phase else {
            return inactive(registration)
        }
        switch phase {
        case .idle, .disabled, .terminated:
            return inactive(registration)
        case .starting:
            return value(
                statusText: "正在连接后台组件…",
                isBusy: true
            )
        case .monitoring(_, let readiness):
            return monitoring(readiness)
        case .failed(let failure):
            return failed(failure)
        }
    }

    private static func inactive(
        _ registration: HostAgentBackgroundRegistrationStatus
    ) -> HostAgentBackgroundHomeReadinessPresentation {
        switch registration {
        case .notRegistered:
            return value(statusText: "后台组件未注册")
        case .requiresApproval:
            return value(statusText: "等待系统允许后台组件")
        case .enabled:
            return value(statusText: "后台组件已注册，尚未开始状态观察")
        case .serviceUnavailable:
            return value(statusText: "后台组件注册状态不可用")
        }
    }

    private static func monitoring(
        _ readiness: HostAgentBackgroundReadinessView
    ) -> HostAgentBackgroundHomeReadinessPresentation {
        guard readiness.failure == nil else {
            return value(
                statusText: "后台组件状态无效",
                errorText: "后台组件状态证据不一致；已停止观察。"
            )
        }
        switch readiness.availability {
        case .notRegistered:
            return value(statusText: "后台组件未注册")
        case .requiresApproval:
            return value(statusText: "等待系统允许后台组件")
        case .serviceUnavailable:
            return value(statusText: "后台组件注册状态不可用")
        case .waitingForHandshake:
            return value(
                statusText: "正在连接后台组件…",
                isBusy: true
            )
        case .incompatible:
            return value(
                statusText: "后台组件版本不兼容",
                errorText: "后台组件版本与 FarPane 不兼容。"
            )
        case .waitingForSnapshot:
            return value(
                statusText: "正在同步后台状态…",
                isBusy: true
            )
        case .sessionUnavailable:
            return value(
                statusText:
                    "远程会话受限：锁屏、登录窗口或其他用户会话暂不支持",
                isRunning: true
            )
        case .rendezvousUnavailable:
            return value(
                statusText: "后台组件尚未连接服务器",
                isRunning: hasAuthoritativeSnapshot(readiness)
            )
        case .runtimeEvidenceInvalid:
            return value(
                statusText: "后台组件状态无效",
                errorText: "后台组件状态证据不一致；已停止观察。"
            )
        case .ready:
            return value(
                statusText: "可被连接",
                isRunning: true,
                isReady: true
            )
        }
    }

    private static func failed(
        _ failure: HostAgentBackgroundActivationFailure
    ) -> HostAgentBackgroundHomeReadinessPresentation {
        switch failure {
        case .runtimeCreation:
            return value(
                statusText: "无法连接后台组件",
                errorText: "无法创建后台状态观察；可以稍后重试。"
            )
        case .runtimeStartRejected:
            return value(
                statusText: "无法连接后台组件",
                errorText: "后台状态观察未能启动；可以稍后重试。"
            )
        case .invalidHealthSequence:
            return value(
                statusText: "后台组件状态无效",
                errorText: "后台组件状态顺序不一致；已停止观察。"
            )
        case .runtimeHealthRejected:
            return value(
                statusText: "后台组件状态无效",
                errorText: "后台组件状态证据无效；已停止观察。"
            )
        case .generationExhausted:
            return value(
                statusText: "后台组件状态不可用",
                errorText: "后台状态计数已耗尽；请重新启动 FarPane。"
            )
        }
    }

    private static func hasAuthoritativeSnapshot(
        _ readiness: HostAgentBackgroundReadinessView
    ) -> Bool {
        readiness.registration == .enabled
            && readiness.runtime.handshake == .compatible
            && readiness.runtime.snapshot == .available
    }

    private static func value(
        statusText: String,
        errorText: String = "",
        isRunning: Bool = false,
        isReady: Bool = false,
        isBusy: Bool = false
    ) -> HostAgentBackgroundHomeReadinessPresentation {
        HostAgentBackgroundHomeReadinessPresentation(
            isRunning: isRunning,
            isReady: isReady,
            isBusy: isBusy,
            statusText: statusText,
            errorText: errorText
        )
    }
}
