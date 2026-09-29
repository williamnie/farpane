import AppKit
import ConnectionCatalog

final class HomeView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var onQuickConnect: ((String) -> Void)?
    var onQuickSendFiles: ((String) -> Void)?
    var onViewerAudioOptInToggle: ((Bool) -> Void)?
    var onOpenServerSettings: (() -> Void)?
    var onDeviceAction: ((UUID, HomeDeviceAction) -> Void)?
    var onHostToggle: ((Bool) -> Void)?
    var onHostClipboardToggle: ((HostClipboardPreference, Bool) -> Void)?
    var onHostFileTransferToggle: ((Bool) -> Void)?
    var onChooseHostFileTransferReceiveRoot: (() -> Void)?
    var onHostAudioToggle: ((Bool) -> Void)?
    var onHostAudioInputSelection: ((String?) -> Void)?
    var onRefreshHostAudioInputs: (() -> Void)?
    var onRevealHostPassword: (() -> Void)?
    var onCopyHostTemporaryPassword: (() -> Void)?
    var onRegenerateHostPassword: (() -> Void)?
    var onSetHostPermanentPassword: (() -> Void)?
    var onClearHostPermanentPassword: (() -> Void)?
    var onApproveHostConnection: ((String) -> Void)?
    var onRejectHostConnection: ((String) -> Void)?
    var onHostSessionAction: ((String, HostSessionHomeAction) -> Void)?
    var onRetryHostCommand: ((String) -> Void)?
    var onOpenSystemPermissionSettings: ((HomeSystemPermissionKind) -> Void)?
    var onRefreshSystemPermissions: (() -> Void)?
    var onReadLocalClipboardText: (() -> String?)?
    var onWriteLocalClipboardText: ((String) -> Bool)?

    let serverButton = NSButton()
    let serverStatusDot = NSView()
    let peerField = NSTextField()
    let peerContainer = NSView()
    let connectButton = AccentButton(title: "连接", target: nil, action: nil)
    let quickSendFilesButton = NSButton(title: "发文件", target: nil, action: nil)
    let viewerAudioOptInSwitch = NSSwitch()
    let filterControl = NSSegmentedControl(
        labels: ["全部", "收藏"], trackingMode: .selectOne, target: nil, action: nil)
    let searchField = NSSearchField()
    let listStack = FlippedStackView()
    let countBadge = NSTextField(labelWithString: "0")
    let statusLabel = NSTextField(labelWithString: "就绪")
    let statusDot = NSView()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let hostSwitch = NSSwitch()
    let hostStatusDot = NSView()
    let hostStatusLabel = NSTextField(labelWithString: "已关闭")
    let hostIDLabel = NSTextField(labelWithString: "本机 ID：—")
    let hostPasswordLabel = NSTextField(labelWithString: "临时密码：未显示")
    let hostIDCopyButton = NSButton()
    let hostPasswordCopyButton = NSButton()
    let hostCopyFeedbackLabel = NSTextField(labelWithString: "")
    let hostRevealButton = NSButton()
    let hostRegenerateButton = NSButton()
    let hostPermanentPasswordLabel = NSTextField(labelWithString: "永久密码：未设置")
    let hostSetPermanentPasswordButton = NSButton()
    let hostClearPermanentPasswordButton = NSButton()
    let hostClipboardReadSwitch = NSSwitch()
    let hostClipboardWriteSwitch = NSSwitch()
    let hostClipboardRichTextReadSwitch = NSSwitch()
    let hostClipboardRichTextWriteSwitch = NSSwitch()
    let hostClipboardImageReadSwitch = NSSwitch()
    let hostClipboardImageWriteSwitch = NSSwitch()
    let hostFileTransferSwitch = NSSwitch()
    let hostFileTransferReceiveRootLabel = NSTextField(labelWithString: "接收文件夹：未选择")
    let hostFileTransferReceiveRootButton = NSButton()
    let hostAudioSwitch = NSSwitch()
    let hostAudioInputPopup = NSPopUpButton()
    let hostAudioInputRefreshButton = NSButton()
    let hostAudioInputStatusLabel = NSTextField(labelWithString: "音频来源：系统音频（原生）")
    let hostMicrophoneAuthorizationLabel = NSTextField(labelWithString: "系统音频使用屏幕录制权限；不需要麦克风权限")
    let hostApprovalContainer = NSView()
    let hostApprovalTitleLabel = NSTextField(labelWithString: "新的远程连接请求")
    let hostApprovalIdentityLabel = NSTextField(wrappingLabelWithString: "")
    let hostApprovalContextLabel = NSTextField(wrappingLabelWithString: "")
    let hostApprovalCapabilityLabel = NSTextField(wrappingLabelWithString: "")
    let hostApprovalExpiryLabel = NSTextField(labelWithString: "")
    let hostApproveButton = NSButton()
    let hostRejectButton = NSButton()
    let hostSessionContainer = NSView()
    let hostSessionTitleLabel = NSTextField(labelWithString: "当前远程会话")
    let hostSessionIdentityLabel = NSTextField(wrappingLabelWithString: "")
    let hostSessionContextLabel = NSTextField(wrappingLabelWithString: "")
    let hostSessionCapabilityLabel = NSTextField(wrappingLabelWithString: "")
    let hostDisableInputButton = NSButton()
    let hostDisableClipboardReadButton = NSButton()
    let hostDisableClipboardWriteButton = NSButton()
    let hostDisableAudioButton = NSButton()
    let hostDisconnectButton = NSButton()
    let hostCommandRetryButton = NSButton()
    let hostMediaDiagnosticLabel = NSTextField(wrappingLabelWithString: "")
    let hostErrorLabel = NSTextField(wrappingLabelWithString: "")
    let pageTabView = NSTabView()
    var sidebarButtons: [HomePage: HomeSidebarButton] = [:]
    var selectedPage: HomePage = .connections
    let permissionChipsLabel = NSTextField(labelWithString: "")
    let permissionSummaryLabel = NSTextField(labelWithString: "正在检测…")
    let permissionSummaryDetailLabel = NSTextField(labelWithString: "")
    var permissionRows: [HomeSystemPermissionKind: HomePermissionRowView] = [:]
    var copyFeedbackGeneration: UInt64 = 0
    var snapshot = HomeSnapshot(
        server: nil, devices: [], statusText: "就绪", errorText: "", connectingPeerID: nil,
        permissions: .unknown,
        host: HostHomeSnapshot(
            isEnabled: false, isControlEnabled: false, isRunning: false, isReady: false,
            allowsHostCommands: false, isStreaming: false, clipboardReadEnabled: false,
            clipboardWriteEnabled: false, allowsClipboardPolicyChange: false, statusText: "已关闭",
            localID: "", temporaryPassword: "", localPermanentPasswordSet: false,
            effectivePermanentPasswordSet: false, usingPresetPassword: false,
            permanentPasswordChangeAllowed: false, pendingApproval: nil, activeSession: nil,
            commandRetry: nil, mediaDiagnosticText: "", errorText: ""))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ snapshot: HomeSnapshot) {
        self.snapshot = snapshot
        let configured = snapshot.server?.isComplete == true
        serverButton.title = snapshot.server?.displayName.nonEmpty ?? "配置服务器"
        serverButton.contentTintColor = configured ? .secondaryLabelColor : .systemOrange
        serverStatusDot.layer?.backgroundColor =
            (configured ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        statusLabel.stringValue = snapshot.statusText
        errorLabel.stringValue = snapshot.errorText
        errorLabel.isHidden = snapshot.errorText.isEmpty
        let canConnect =
            snapshot.server?.isComplete == true && snapshot.connectingPeerID == nil
            && !peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        connectButton.isEnabled = canConnect
        quickSendFilesButton.isEnabled = canConnect
        peerField.isEnabled = snapshot.connectingPeerID == nil
        connectButton.title = snapshot.connectingPeerID == nil ? "连接" : "连接中…"
        serverButton.isEnabled = snapshot.connectingPeerID == nil
        viewerAudioOptInSwitch.state = snapshot.viewerAudioOptIn ? .on : .off
        viewerAudioOptInSwitch.isEnabled = snapshot.connectingPeerID == nil
        hostSwitch.state = snapshot.host.isEnabled ? .on : .off
        hostSwitch.isEnabled = snapshot.connectingPeerID == nil && snapshot.host.isControlEnabled
        for entry in clipboardControls {
            entry.control.state = snapshot.host[keyPath: entry.value] ? .on : .off
            entry.control.isEnabled =
                snapshot.connectingPeerID == nil && snapshot.host.allowsClipboardPolicyChange
        }
        hostFileTransferSwitch.state = snapshot.host.fileTransferEnabled ? .on : .off
        let fileTransferPolicyInteractive =
            snapshot.connectingPeerID == nil && snapshot.host.allowsFileTransferPolicyChange
        hostFileTransferSwitch.isEnabled = fileTransferPolicyInteractive
        hostFileTransferReceiveRootButton.isEnabled = fileTransferPolicyInteractive
        hostFileTransferReceiveRootButton.title =
            snapshot.host.fileTransferEnabled ? "更改位置" : "选择并启用"
        hostFileTransferReceiveRootLabel.stringValue =
            "接收文件夹：\(snapshot.host.fileTransferReceiveRootName.nonEmpty ?? "未选择")"
        hostAudioSwitch.state = snapshot.host.audioEnabled ? .on : .off
        hostAudioSwitch.isEnabled =
            snapshot.connectingPeerID == nil && snapshot.host.allowsAudioPolicyChange
        applyHostAudioInputSelection(snapshot.host)
        hostMicrophoneAuthorizationLabel.stringValue = snapshot.host.microphoneAuthorizationText
        hostStatusLabel.stringValue = snapshot.host.statusText
        hostStatusDot.layer?.backgroundColor = hostStatusColor(snapshot.host).cgColor
        hostIDLabel.stringValue = snapshot.host.localID.nonEmpty ?? "—"
        hostIDCopyButton.isEnabled = !snapshot.host.localID.isEmpty
        hostPasswordLabel.stringValue = snapshot.host.temporaryPassword.nonEmpty ?? "未显示"
        hostRevealButton.title = snapshot.host.temporaryPassword.isEmpty ? "显示" : "隐藏"
        hostRevealButton.isEnabled = snapshot.host.allowsHostCommands
        hostPasswordCopyButton.isEnabled = hostRevealButton.isEnabled
        hostRegenerateButton.isEnabled = snapshot.host.allowsHostCommands
        hostPermanentPasswordLabel.stringValue = permanentPasswordStatus(snapshot.host)
        if snapshot.host.localPermanentPasswordSet {
            hostSetPermanentPasswordButton.title = "更改"
        } else if snapshot.host.usingPresetPassword {
            hostSetPermanentPasswordButton.title = "替换"
        } else {
            hostSetPermanentPasswordButton.title = "设置"
        }
        hostSetPermanentPasswordButton.isEnabled =
            snapshot.host.allowsHostCommands && snapshot.host.permanentPasswordChangeAllowed
        hostClearPermanentPasswordButton.isEnabled =
            snapshot.host.allowsHostCommands && snapshot.host.permanentPasswordChangeAllowed
            && snapshot.host.localPermanentPasswordSet
        if let approval = snapshot.host.pendingApproval {
            hostApprovalIdentityLabel.stringValue = approval.remoteIdentityText
            hostApprovalContextLabel.stringValue = approval.contextText
            hostApprovalCapabilityLabel.stringValue = approval.capabilityText
            hostApprovalExpiryLabel.stringValue = approval.expiryText
            hostApproveButton.title = approval.isResolving ? "处理中…" : "允许一次"
            hostApproveButton.isEnabled =
                approval.enabledActions.contains(.approve) && !approval.isResolving
            hostRejectButton.isEnabled =
                approval.enabledActions.contains(.reject) && !approval.isResolving
            hostApprovalContainer.isHidden = false
        } else {
            hostApprovalContainer.isHidden = true
            hostApproveButton.isEnabled = false
            hostRejectButton.isEnabled = false
        }
        if let session = snapshot.host.activeSession {
            hostSessionIdentityLabel.stringValue = session.remoteIdentityText
            hostSessionContextLabel.stringValue = session.contextText
            hostSessionCapabilityLabel.stringValue = session.capabilityText
            let actionInFlight = session.pendingAction != nil
            configureSessionButton(
                hostDisableInputButton, title: "停止键鼠控制", action: .disableKeyboardAndMouse,
                session: session, capabilityAvailable: session.canDisableKeyboardAndMouse)
            configureSessionButton(
                hostDisableClipboardReadButton, title: "停止远端读取", action: .disableClipboardRead,
                session: session, capabilityAvailable: session.canDisableClipboardRead)
            configureSessionButton(
                hostDisableClipboardWriteButton, title: "停止远端写入", action: .disableClipboardWrite,
                session: session, capabilityAvailable: session.canDisableClipboardWrite)
            configureSessionButton(
                hostDisableAudioButton, title: "停止系统音频", action: .disableSystemAudio,
                session: session, capabilityAvailable: session.canDisableSystemAudio)
            hostDisconnectButton.title = session.pendingAction == .disconnect ? "正在断开…" : "断开连接"
            hostDisconnectButton.isEnabled =
                session.enabledActions.contains(.disconnect) && !actionInFlight
            hostSessionContainer.isHidden = false
        } else {
            hostSessionContainer.isHidden = true
            for button in [
                hostDisableInputButton, hostDisableClipboardReadButton,
                hostDisableClipboardWriteButton, hostDisableAudioButton, hostDisconnectButton,
            ] { button.isEnabled = false }
        }
        if let retry = snapshot.host.commandRetry {
            hostCommandRetryButton.title = retry.title
            hostCommandRetryButton.setAccessibilityLabel(retry.title)
            hostCommandRetryButton.isEnabled = true
            hostCommandRetryButton.isHidden = false
        } else {
            hostCommandRetryButton.isEnabled = false
            hostCommandRetryButton.isHidden = true
        }
        hostMediaDiagnosticLabel.stringValue = snapshot.host.mediaDiagnosticText
        hostMediaDiagnosticLabel.isHidden = snapshot.host.mediaDiagnosticText.isEmpty
        hostErrorLabel.stringValue = snapshot.host.errorText
        hostErrorLabel.isHidden = snapshot.host.errorText.isEmpty
        applyPermissionSnapshot(snapshot.permissions)
        countBadge.stringValue = "\(snapshot.devices.count)"
        renderDevices()
    }

    func applyPermissionSnapshot(_ permissions: HomeSystemPermissionSnapshot) {
        let granted = permissions.requiredGrantedCount
        let required = permissions.requiredCount
        permissionChipsLabel.attributedStringValue = permissionChipsText(permissions)
        permissionSummaryLabel.stringValue =
            granted == required ? "关键权限均已就绪" : "还需要 \(required - granted) 项系统授权"
        permissionSummaryLabel.textColor = granted == required ? .systemGreen : .systemOrange
        permissionSummaryDetailLabel.stringValue = "FarPane 只读取系统返回的授权状态，不能自行授予权限。"
        for kind in HomeSystemPermissionKind.allCases {
            permissionRows[kind]?.apply(permissions[kind])
        }
    }

    /// 授权 chip 条：✓/✗ + 权限名，按状态着色

    func permissionChipsText(_ permissions: HomeSystemPermissionSnapshot) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let all = HomeSystemPermissionKind.allCases
        for (index, kind) in all.enumerated() {
            let granted = permissions[kind].isGranted
            let color: NSColor = granted ? HomePalette.accent : .systemOrange
            text.append(
                NSAttributedString(
                    string: (granted ? "✓ " : "✗ ") + kind.title,
                    attributes: [.font: font, .foregroundColor: color]))
            if index < all.count - 1 {
                text.append(NSAttributedString(string: "   ", attributes: [.font: font]))
            }
        }
        return text
    }

    func hostStatusColor(_ host: HostHomeSnapshot) -> NSColor {
        guard host.isEnabled else { return .tertiaryLabelColor }
        if !host.errorText.isEmpty { return .systemOrange }
        return host.isReady || host.isStreaming ? .systemGreen : .systemYellow
    }

    func permanentPasswordStatus(_ host: HostHomeSnapshot) -> String {
        if !host.permanentPasswordChangeAllowed {
            return host.effectivePermanentPasswordSet ? "由管理员管理" : "不允许更改"
        }
        if host.localPermanentPasswordSet { return "已设置" }
        if host.usingPresetPassword || host.effectivePermanentPasswordSet { return "预设密码生效" }
        return "未设置"
    }

    func configureSessionButton(
        _ button: NSButton, title: String, action: HostSessionHomeAction,
        session: HostActiveSessionHomeSnapshot, capabilityAvailable: Bool
    ) {
        button.title = session.pendingAction == action ? "处理中…" : title
        button.isHidden = !capabilityAvailable
        button.isEnabled =
            session.enabledActions.contains(action) && capabilityAvailable
            && session.pendingAction == nil
    }
}
