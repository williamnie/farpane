package enum HostAgentBackgroundRegistrationPresentationTone:
    Equatable,
    Sendable
{
    case neutral
    case progress
    case attention
    case success
    case failure
}

package struct HostAgentBackgroundRegistrationPresentation:
    Equatable,
    Sendable
{
    package let statusText: String
    package let errorText: String
    package let tone: HostAgentBackgroundRegistrationPresentationTone
    package let isBusy: Bool
    package let canRetry: Bool

    package init(
        statusText: String,
        errorText: String,
        tone: HostAgentBackgroundRegistrationPresentationTone,
        isBusy: Bool,
        canRetry: Bool
    ) {
        self.statusText = statusText
        self.errorText = errorText
        self.tone = tone
        self.isBusy = isBusy
        self.canRetry = canRetry
    }
}

/// Converts the typed registration flow into bounded, user-facing copy. It
/// intentionally describes component registration rather than Host readiness:
/// readiness still requires the separate live background-health evidence.
package enum HostAgentBackgroundRegistrationPresentationPolicy {
    package static func presentation(
        for view: HostAgentBackgroundRegistrationUXView
    ) -> HostAgentBackgroundRegistrationPresentation {
        switch view.phase {
        case .idle:
            return output("后台连接尚未启用")
        case .awaitingConfirmation(let prompt):
            switch prompt.kind {
            case .backgroundPersistence:
                return output(
                    "等待确认后台连接",
                    tone: .attention
                )
            case .loginItemsApproval:
                return output(
                    "等待系统授权",
                    error: "请在“系统设置 > 通用 > 登录项与扩展”中允许 FarPane。",
                    tone: .attention,
                    canRetry: true
                )
            }
        case .preparingLegacyHost:
            return progress("正在停止旧的被控端…")
        case .migrationBlocked(let blockers):
            let error: String
            if blockers.contains(.activeSession) {
                error = "当前仍有远程会话，请结束会话后重试。"
            } else if blockers.contains(.pendingApproval) {
                error = "当前仍有待处理的连接请求，请处理后重试。"
            } else {
                error = "旧的被控端尚未完全停止，请稍后重试。"
            }
            return output(
                "后台连接尚未启用",
                error: error,
                tone: .attention,
                canRetry: true
            )
        case .registering:
            return progress("正在注册后台组件…")
        case .registered:
            return output("后台组件已注册", tone: .success)
        case .navigating:
            return progress("正在打开登录项设置…")
        case .navigationRequested:
            return output(
                "等待系统授权",
                error: "请在系统设置的“登录项与扩展”中允许 FarPane。",
                tone: .attention,
                canRetry: true
            )
        case .approvalNoLongerRequired:
            if view.registration == .enabled {
                return output("后台组件已注册", tone: .success)
            }
            return output(
                "后台连接尚未启用",
                error: "后台组件状态已变化，请重新检查后重试。",
                tone: .attention,
                canRetry: true
            )
        case .cancelled:
            return output("已取消后台连接设置")
        case .failed(let failure):
            return output(
                "后台连接启用失败",
                error: failureText(failure),
                tone: .failure,
                canRetry: true
            )
        }
    }

    private static func failureText(
        _ failure: HostAgentBackgroundRegistrationUXFailure
    ) -> String {
        switch failure {
        case .migration(let migration):
            switch migration {
            case .assessment(.evidenceUnavailable):
                return "无法读取旧被控端完整状态，请稍后重试。"
            case .assessment(.inconsistentEvidence):
                return "旧被控端状态不一致，请重新启动 FarPane 后重试。"
            case .quiescenceRequestFailed:
                return "无法确认旧被控端已停止，请重新启动 FarPane 后重试。"
            }
        case .registration(let registration):
            switch registration {
            case .invalidLaunchAgent, .invalidApplication,
                 .invalidCodeSignature, .distributionNotarizationRequired:
                return "当前构建无法安全注册后台组件。"
            case .serviceUnavailable:
                return "无法读取后台组件状态，请稍后重试。"
            case .registrationNotEffective:
                return "后台组件注册未生效，请稍后重试。"
            case .unregistrationNotEffective, .generationExhausted:
                return "后台连接状态异常，请重新启动 FarPane 后重试。"
            }
        case .approvalNavigation(let navigation):
            switch navigation {
            case .serviceUnavailable:
                return "无法打开登录项设置，请手动前往系统设置。"
            case .generationExhausted:
                return "后台连接状态异常，请重新启动 FarPane 后重试。"
            }
        case .invalidMigrationResult, .invalidRegistrationResult,
             .invalidApprovalNavigationResult, .generationExhausted:
            return "后台连接状态异常，请重新启动 FarPane 后重试。"
        }
    }

    private static func progress(
        _ statusText: String
    ) -> HostAgentBackgroundRegistrationPresentation {
        output(statusText, tone: .progress, isBusy: true)
    }

    private static func output(
        _ statusText: String,
        error: String = "",
        tone: HostAgentBackgroundRegistrationPresentationTone = .neutral,
        isBusy: Bool = false,
        canRetry: Bool = false
    ) -> HostAgentBackgroundRegistrationPresentation {
        HostAgentBackgroundRegistrationPresentation(
            statusText: statusText,
            errorText: error,
            tone: tone,
            isBusy: isBusy,
            canRetry: canRetry
        )
    }
}
