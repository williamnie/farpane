package struct HostAgentBackgroundUnregistrationPresentation:
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

/// Maps unregistration state to bounded user-facing copy without treating an
/// API return as proof that the background service has stopped.
package enum HostAgentBackgroundUnregistrationPresentationPolicy {
    package static func presentation(
        for view: HostAgentBackgroundUnregistrationUXView
    ) -> HostAgentBackgroundUnregistrationPresentation {
        switch view.phase {
        case .idle:
            return output("后台连接状态未变")
        case .awaitingConfirmation:
            return output(
                "等待确认关闭后台连接",
                tone: .attention
            )
        case .unregistering:
            return output(
                "正在关闭后台连接…",
                tone: .progress,
                isBusy: true
            )
        case .unregistered:
            return output("后台连接已关闭", tone: .success)
        case .cancelled:
            return output("已取消关闭后台连接")
        case .failed(let failure):
            return output(
                "后台连接关闭失败",
                error: failureText(failure),
                tone: .failure,
                canRetry: true
            )
        }
    }

    private static func failureText(
        _ failure: HostAgentBackgroundUnregistrationUXFailure
    ) -> String {
        switch failure {
        case .mutation(.serviceUnavailable):
            return "无法读取后台组件状态，请稍后重试。"
        case .mutation(.unregistrationNotEffective):
            return "后台组件仍处于注册状态，请稍后重试。"
        case .mutation(.invalidLaunchAgent),
             .mutation(.invalidApplication),
             .mutation(.invalidCodeSignature),
             .mutation(.distributionNotarizationRequired),
             .mutation(.registrationNotEffective),
             .mutation(.generationExhausted),
             .invalidMutationResult,
             .generationExhausted:
            return "后台连接状态异常，请重新启动 FarPane 后重试。"
        }
    }

    private static func output(
        _ statusText: String,
        error: String = "",
        tone: HostAgentBackgroundRegistrationPresentationTone = .neutral,
        isBusy: Bool = false,
        canRetry: Bool = false
    ) -> HostAgentBackgroundUnregistrationPresentation {
        HostAgentBackgroundUnregistrationPresentation(
            statusText: statusText,
            errorText: error,
            tone: tone,
            isBusy: isBusy,
            canRetry: canRetry
        )
    }
}
