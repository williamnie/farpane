import AppKit
import ConnectionCatalog

struct HomeDeviceItem: Equatable {
    let device: SavedDevice
    let hasSavedPassword: Bool
}

enum HomeSystemPermissionKind: CaseIterable, Hashable {
    case screenRecording
    case accessibility
    case inputMonitoring
    case microphone

    var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        case .microphone: return "麦克风"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "允许远端看到本机画面"
        case .accessibility: return "允许远端控制鼠标和键盘"
        case .inputMonitoring: return "接收完整键盘事件与系统快捷键"
        case .microphone: return "仅在开启远程音频时需要"
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .microphone: return "mic"
        }
    }

    var isRequired: Bool { self != .microphone }
}

enum HomeSystemPermissionState: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted

    var isGranted: Bool { self == .granted }

    var statusText: String {
        switch self {
        case .granted: return "已授权"
        case .notDetermined: return "待授权"
        case .denied: return "未授权"
        case .restricted: return "受系统限制"
        }
    }
}

struct HomeSystemPermissionSnapshot: Equatable {
    var screenRecording: HomeSystemPermissionState
    var accessibility: HomeSystemPermissionState
    var inputMonitoring: HomeSystemPermissionState
    var microphone: HomeSystemPermissionState

    static let unknown = HomeSystemPermissionSnapshot(
        screenRecording: .notDetermined,
        accessibility: .notDetermined,
        inputMonitoring: .notDetermined,
        microphone: .notDetermined
    )

    subscript(_ kind: HomeSystemPermissionKind) -> HomeSystemPermissionState {
        switch kind {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .microphone: return microphone
        }
    }

    var requiredGrantedCount: Int {
        HomeSystemPermissionKind.allCases.filter {
            $0.isRequired && self[$0].isGranted
        }.count
    }

    var requiredCount: Int {
        HomeSystemPermissionKind.allCases.filter(\.isRequired).count
    }
}

struct HostApprovalHomeSnapshot: Equatable {
    var connectionID: String
    var remoteIdentityText: String
    var contextText: String
    var capabilityText: String
    var expiryText: String
    var isResolving: Bool
    var enabledActions: Set<HostApprovalHomeAction>
}

enum HostApprovalHomeAction: Equatable, Hashable {
    case approve
    case reject
}

enum HostSessionHomeAction: Equatable, Hashable {
    case disableKeyboardAndMouse
    case disableClipboardRead
    case disableClipboardWrite
    case disableClipboard
    case disableSystemAudio
    case disconnect
}

struct HostActiveSessionHomeSnapshot: Equatable {
    var connectionID: String
    var remoteIdentityText: String
    var contextText: String
    var capabilityText: String
    var canDisableKeyboardAndMouse: Bool
    var canDisableClipboardRead: Bool
    var canDisableClipboardWrite: Bool
    var canDisableClipboard: Bool
    var canDisableSystemAudio: Bool
    var pendingAction: HostSessionHomeAction?
    var enabledActions: Set<HostSessionHomeAction>
}

struct HostCommandRetryHomeSnapshot: Equatable {
    var connectionID: String
    var title: String
}

struct HostHomeSnapshot: Equatable {
    var isEnabled: Bool
    var isControlEnabled: Bool
    var isRunning: Bool
    var isReady: Bool
    var allowsHostCommands: Bool
    var isStreaming: Bool
    var clipboardReadEnabled: Bool
    var clipboardWriteEnabled: Bool
    var clipboardRichTextReadEnabled: Bool = false
    var clipboardRichTextWriteEnabled: Bool = false
    var clipboardImageReadEnabled: Bool = false
    var clipboardImageWriteEnabled: Bool = false
    var allowsClipboardPolicyChange: Bool
    var fileTransferEnabled: Bool = false
    var fileTransferReceiveRootName: String = ""
    var allowsFileTransferPolicyChange: Bool = false
    var audioEnabled: Bool = false
    var audioInputDeviceNames: [String] = []
    var audioInputDeviceName: String?
    var audioInputDeviceAvailable: Bool = true
    var microphoneAuthorizationText: String =
        "系统音频使用屏幕录制权限；不需要麦克风权限"
    var allowsAudioPolicyChange: Bool = false
    var statusText: String
    var localID: String
    var temporaryPassword: String
    var localPermanentPasswordSet: Bool
    var effectivePermanentPasswordSet: Bool
    var usingPresetPassword: Bool
    var permanentPasswordChangeAllowed: Bool
    var pendingApproval: HostApprovalHomeSnapshot?
    var activeSession: HostActiveSessionHomeSnapshot?
    var commandRetry: HostCommandRetryHomeSnapshot?
    var mediaDiagnosticText: String
    var errorText: String
}

struct HomeSnapshot: Equatable {
    var server: ServerConfiguration?
    var devices: [HomeDeviceItem]
    var statusText: String
    var errorText: String
    var connectingPeerID: String?
    var viewerAudioOptIn: Bool = false
    var permissions: HomeSystemPermissionSnapshot = .unknown
    var host: HostHomeSnapshot
}

enum HomeDeviceAction {
    case connect
    case sendFiles
    case toggleFavorite
    case rename
    case updatePassword
    case deletePassword
    case deleteDevice
}

private enum HomePage: String, CaseIterable {
    case connections
    case permissions
    case sharing

    var title: String {
        switch self {
        case .connections: return "设备"
        case .permissions: return "授权与安全"
        case .sharing: return "共享设置"
        }
    }

    var symbolName: String {
        switch self {
        case .connections: return "display.2"
        case .permissions: return "checkmark.shield"
        case .sharing: return "slider.horizontal.3"
        }
    }
}

private enum HomePalette {
    static let accent = NSColor(
        calibratedRed: 0.41,
        green: 0.97,
        blue: 0.76,
        alpha: 1
    )
    static let panel = NSColor(
        calibratedRed: 0.082,
        green: 0.102,
        blue: 0.129,
        alpha: 1
    )
    static let panelHover = NSColor(
        calibratedRed: 0.102,
        green: 0.129,
        blue: 0.165,
        alpha: 1
    )
    /// accent 上的深色文字
    static let inkOnAccent = NSColor(
        calibratedRed: 0.024,
        green: 0.137,
        blue: 0.102,
        alpha: 1
    )
}

final class HomeView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var onQuickConnect: ((String) -> Void)?
    var onQuickSendFiles: ((String) -> Void)?
    var onViewerAudioOptInToggle: ((Bool) -> Void)?
    var onOpenServerSettings: (() -> Void)?
    var onDeviceAction: ((UUID, HomeDeviceAction) -> Void)?
    var onHostToggle: ((Bool) -> Void)?
    var onHostClipboardReadToggle: ((Bool) -> Void)?
    var onHostClipboardWriteToggle: ((Bool) -> Void)?
    var onHostClipboardRichTextReadToggle: ((Bool) -> Void)?
    var onHostClipboardRichTextWriteToggle: ((Bool) -> Void)?
    var onHostClipboardImageReadToggle: ((Bool) -> Void)?
    var onHostClipboardImageWriteToggle: ((Bool) -> Void)?
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

    private let serverButton = NSButton()
    private let serverStatusDot = NSView()
    private let peerField = NSTextField()
    private let peerContainer = NSView()
    private let connectButton = AccentButton(title: "连接", target: nil, action: nil)
    private let quickSendFilesButton = NSButton(
        title: "发文件",
        target: nil,
        action: nil
    )
    private let viewerAudioOptInSwitch = NSSwitch()
    private let filterControl = NSSegmentedControl(
        labels: ["全部", "收藏"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let listStack = FlippedStackView()
    private let countBadge = NSTextField(labelWithString: "0")
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let statusDot = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let hostSwitch = NSSwitch()
    private let hostStatusDot = NSView()
    private let hostStatusLabel = NSTextField(labelWithString: "已关闭")
    private let hostIDLabel = NSTextField(labelWithString: "本机 ID：—")
    private let hostPasswordLabel = NSTextField(labelWithString: "临时密码：未显示")
    private let hostIDCopyButton = NSButton()
    private let hostPasswordCopyButton = NSButton()
    private let hostCopyFeedbackLabel = NSTextField(labelWithString: "")
    private let hostRevealButton = NSButton()
    private let hostRegenerateButton = NSButton()
    private let hostPermanentPasswordLabel = NSTextField(labelWithString: "永久密码：未设置")
    private let hostSetPermanentPasswordButton = NSButton()
    private let hostClearPermanentPasswordButton = NSButton()
    private let hostClipboardReadSwitch = NSSwitch()
    private let hostClipboardWriteSwitch = NSSwitch()
    private let hostClipboardRichTextReadSwitch = NSSwitch()
    private let hostClipboardRichTextWriteSwitch = NSSwitch()
    private let hostClipboardImageReadSwitch = NSSwitch()
    private let hostClipboardImageWriteSwitch = NSSwitch()
    private let hostFileTransferSwitch = NSSwitch()
    private let hostFileTransferReceiveRootLabel = NSTextField(
        labelWithString: "接收文件夹：未选择"
    )
    private let hostFileTransferReceiveRootButton = NSButton()
    private let hostAudioSwitch = NSSwitch()
    private let hostAudioInputPopup = NSPopUpButton()
    private let hostAudioInputRefreshButton = NSButton()
    private let hostAudioInputStatusLabel = NSTextField(
        labelWithString: "音频来源：系统音频（原生）"
    )
    private let hostMicrophoneAuthorizationLabel = NSTextField(
        labelWithString: "系统音频使用屏幕录制权限；不需要麦克风权限"
    )
    private let hostApprovalContainer = NSView()
    private let hostApprovalTitleLabel = NSTextField(labelWithString: "新的远程连接请求")
    private let hostApprovalIdentityLabel = NSTextField(wrappingLabelWithString: "")
    private let hostApprovalContextLabel = NSTextField(wrappingLabelWithString: "")
    private let hostApprovalCapabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let hostApprovalExpiryLabel = NSTextField(labelWithString: "")
    private let hostApproveButton = NSButton()
    private let hostRejectButton = NSButton()
    private let hostSessionContainer = NSView()
    private let hostSessionTitleLabel = NSTextField(labelWithString: "当前远程会话")
    private let hostSessionIdentityLabel = NSTextField(wrappingLabelWithString: "")
    private let hostSessionContextLabel = NSTextField(wrappingLabelWithString: "")
    private let hostSessionCapabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let hostDisableInputButton = NSButton()
    private let hostDisableClipboardReadButton = NSButton()
    private let hostDisableClipboardWriteButton = NSButton()
    private let hostDisableAudioButton = NSButton()
    private let hostDisconnectButton = NSButton()
    private let hostCommandRetryButton = NSButton()
    private let hostMediaDiagnosticLabel = NSTextField(wrappingLabelWithString: "")
    private let hostErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let pageTabView = NSTabView()
    private var sidebarButtons: [HomePage: HomeSidebarButton] = [:]
    private var selectedPage: HomePage = .connections
    private let permissionChipsLabel = NSTextField(labelWithString: "")
    private let permissionSummaryLabel = NSTextField(labelWithString: "正在检测…")
    private let permissionSummaryDetailLabel = NSTextField(labelWithString: "")
    private var permissionRows: [HomeSystemPermissionKind: HomePermissionRowView] = [:]
    private var copyFeedbackGeneration: UInt64 = 0
    private var snapshot = HomeSnapshot(
        server: nil,
        devices: [],
        statusText: "就绪",
        errorText: "",
        connectingPeerID: nil,
        permissions: .unknown,
        host: HostHomeSnapshot(
            isEnabled: false,
            isControlEnabled: false,
            isRunning: false,
            isReady: false,
            allowsHostCommands: false,
            isStreaming: false,
            clipboardReadEnabled: false,
            clipboardWriteEnabled: false,
            allowsClipboardPolicyChange: false,
            statusText: "已关闭",
            localID: "",
            temporaryPassword: "",
            localPermanentPasswordSet: false,
            effectivePermanentPasswordSet: false,
            usingPresetPassword: false,
            permanentPasswordChangeAllowed: false,
            pendingApproval: nil,
            activeSession: nil,
            commandRetry: nil,
            mediaDiagnosticText: "",
            errorText: ""
        )
    )

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
        serverStatusDot.layer?.backgroundColor = (configured ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        statusLabel.stringValue = snapshot.statusText
        errorLabel.stringValue = snapshot.errorText
        errorLabel.isHidden = snapshot.errorText.isEmpty
        let canConnect = snapshot.server?.isComplete == true
            && snapshot.connectingPeerID == nil
            && !peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        connectButton.isEnabled = canConnect
        quickSendFilesButton.isEnabled = canConnect
        peerField.isEnabled = snapshot.connectingPeerID == nil
        connectButton.title = snapshot.connectingPeerID == nil ? "连接" : "连接中…"
        serverButton.isEnabled = snapshot.connectingPeerID == nil
        viewerAudioOptInSwitch.state = snapshot.viewerAudioOptIn ? .on : .off
        viewerAudioOptInSwitch.isEnabled = snapshot.connectingPeerID == nil
        hostSwitch.state = snapshot.host.isEnabled ? .on : .off
        hostSwitch.isEnabled = snapshot.connectingPeerID == nil
            && snapshot.host.isControlEnabled
        hostClipboardReadSwitch.state = snapshot.host.clipboardReadEnabled
            ? .on : .off
        hostClipboardWriteSwitch.state = snapshot.host.clipboardWriteEnabled
            ? .on : .off
        hostClipboardRichTextReadSwitch.state = snapshot.host
            .clipboardRichTextReadEnabled ? .on : .off
        hostClipboardRichTextWriteSwitch.state = snapshot.host
            .clipboardRichTextWriteEnabled ? .on : .off
        hostClipboardImageReadSwitch.state = snapshot.host
            .clipboardImageReadEnabled ? .on : .off
        hostClipboardImageWriteSwitch.state = snapshot.host
            .clipboardImageWriteEnabled ? .on : .off
        let clipboardPolicyInteractive = snapshot.connectingPeerID == nil
            && snapshot.host.allowsClipboardPolicyChange
        hostClipboardReadSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardWriteSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardRichTextReadSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardRichTextWriteSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardImageReadSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardImageWriteSwitch.isEnabled = clipboardPolicyInteractive
        hostFileTransferSwitch.state = snapshot.host.fileTransferEnabled
            ? .on : .off
        let fileTransferPolicyInteractive = snapshot.connectingPeerID == nil
            && snapshot.host.allowsFileTransferPolicyChange
        hostFileTransferSwitch.isEnabled = fileTransferPolicyInteractive
        hostFileTransferReceiveRootButton.isEnabled =
            fileTransferPolicyInteractive
        hostFileTransferReceiveRootButton.title = snapshot.host
            .fileTransferEnabled ? "更改位置" : "选择并启用"
        hostFileTransferReceiveRootLabel.stringValue =
            "接收文件夹：\(snapshot.host.fileTransferReceiveRootName.nonEmpty ?? "未选择")"
        hostAudioSwitch.state = snapshot.host.audioEnabled ? .on : .off
        hostAudioSwitch.isEnabled = snapshot.connectingPeerID == nil
            && snapshot.host.allowsAudioPolicyChange
        applyHostAudioInputSelection(snapshot.host)
        hostMicrophoneAuthorizationLabel.stringValue = snapshot.host
            .microphoneAuthorizationText
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
        hostSetPermanentPasswordButton.isEnabled = snapshot.host.allowsHostCommands
            && snapshot.host.permanentPasswordChangeAllowed
        hostClearPermanentPasswordButton.isEnabled = snapshot.host.allowsHostCommands
            && snapshot.host.permanentPasswordChangeAllowed
            && snapshot.host.localPermanentPasswordSet
        if let approval = snapshot.host.pendingApproval {
            hostApprovalIdentityLabel.stringValue = approval.remoteIdentityText
            hostApprovalContextLabel.stringValue = approval.contextText
            hostApprovalCapabilityLabel.stringValue = approval.capabilityText
            hostApprovalExpiryLabel.stringValue = approval.expiryText
            hostApproveButton.title = approval.isResolving ? "处理中…" : "允许一次"
            hostApproveButton.isEnabled = approval.enabledActions
                .contains(.approve)
                && !approval.isResolving
            hostRejectButton.isEnabled = approval.enabledActions
                .contains(.reject)
                && !approval.isResolving
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
                hostDisableInputButton,
                title: "停止键鼠控制",
                action: .disableKeyboardAndMouse,
                session: session,
                capabilityAvailable: session.canDisableKeyboardAndMouse
            )
            configureSessionButton(
                hostDisableClipboardReadButton,
                title: "停止远端读取",
                action: .disableClipboardRead,
                session: session,
                capabilityAvailable: session.canDisableClipboardRead
            )
            configureSessionButton(
                hostDisableClipboardWriteButton,
                title: "停止远端写入",
                action: .disableClipboardWrite,
                session: session,
                capabilityAvailable: session.canDisableClipboardWrite
            )
            configureSessionButton(
                hostDisableAudioButton,
                title: "停止系统音频",
                action: .disableSystemAudio,
                session: session,
                capabilityAvailable: session.canDisableSystemAudio
            )
            hostDisconnectButton.title = session.pendingAction == .disconnect
                ? "正在断开…"
                : "断开连接"
            hostDisconnectButton.isEnabled = session.enabledActions
                .contains(.disconnect)
                && !actionInFlight
            hostSessionContainer.isHidden = false
        } else {
            hostSessionContainer.isHidden = true
            for button in [
                hostDisableInputButton,
                hostDisableClipboardReadButton,
                hostDisableClipboardWriteButton,
                hostDisableAudioButton,
                hostDisconnectButton,
            ] {
                button.isEnabled = false
            }
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

    private func applyPermissionSnapshot(
        _ permissions: HomeSystemPermissionSnapshot
    ) {
        let granted = permissions.requiredGrantedCount
        let required = permissions.requiredCount
        permissionChipsLabel.attributedStringValue = permissionChipsText(permissions)
        permissionSummaryLabel.stringValue = granted == required
            ? "关键权限均已就绪"
            : "还需要 \(required - granted) 项系统授权"
        permissionSummaryLabel.textColor = granted == required
            ? .systemGreen
            : .systemOrange
        permissionSummaryDetailLabel.stringValue =
            "FarPane 只读取系统返回的授权状态，不能自行授予权限。"
        for kind in HomeSystemPermissionKind.allCases {
            permissionRows[kind]?.apply(permissions[kind])
        }
    }

    /// 授权 chip 条：✓/✗ + 权限名，按状态着色
    private func permissionChipsText(
        _ permissions: HomeSystemPermissionSnapshot
    ) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        let all = HomeSystemPermissionKind.allCases
        for (index, kind) in all.enumerated() {
            let granted = permissions[kind].isGranted
            let color: NSColor = granted ? HomePalette.accent : .systemOrange
            text.append(NSAttributedString(
                string: (granted ? "✓ " : "✗ ") + kind.title,
                attributes: [.font: font, .foregroundColor: color]
            ))
            if index < all.count - 1 {
                text.append(NSAttributedString(
                    string: "   ",
                    attributes: [.font: font]
                ))
            }
        }
        return text
    }

    private func hostStatusColor(_ host: HostHomeSnapshot) -> NSColor {
        guard host.isEnabled else { return .tertiaryLabelColor }
        if !host.errorText.isEmpty { return .systemOrange }
        return host.isReady || host.isStreaming
            ? .systemGreen
            : .systemYellow
    }

    private func permanentPasswordStatus(_ host: HostHomeSnapshot) -> String {
        if !host.permanentPasswordChangeAllowed {
            return host.effectivePermanentPasswordSet
                ? "由管理员管理"
                : "不允许更改"
        }
        if host.localPermanentPasswordSet {
            return "已设置"
        }
        if host.usingPresetPassword || host.effectivePermanentPasswordSet {
            return "预设密码生效"
        }
        return "未设置"
    }

    private func configureSessionButton(
        _ button: NSButton,
        title: String,
        action: HostSessionHomeAction,
        session: HostActiveSessionHomeSnapshot,
        capabilityAvailable: Bool
    ) {
        button.title = session.pendingAction == action ? "处理中…" : title
        button.isHidden = !capabilityAvailable
        button.isEnabled = session.enabledActions.contains(action)
            && capabilityAvailable
            && session.pendingAction == nil
    }

    func focusQuickConnect() {
        guard selectedPage == .connections else { return }
        window?.makeFirstResponder(peerField)
    }

    private func configure() {
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(
            calibratedRed: 0.043,
            green: 0.051,
            blue: 0.063,
            alpha: 1
        ).cgColor

        serverStatusDot.wantsLayer = true
        serverStatusDot.layer?.cornerRadius = 4
        serverStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            serverStatusDot.widthAnchor.constraint(equalToConstant: 8),
            serverStatusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        serverButton.bezelStyle = .inline
        serverButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "服务器设置"
        )
        serverButton.imagePosition = .imageLeading
        serverButton.target = self
        serverButton.action = #selector(openServerSettings)
        serverButton.toolTip = "服务器设置"

        // ---------- 快速连接卡片 ----------
        peerField.placeholderString = "输入远端 ID"
        peerField.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        peerField.isBordered = false
        peerField.drawsBackground = false
        peerField.focusRingType = .none
        peerField.delegate = self
        peerField.target = self
        peerField.action = #selector(connectQuickly)
        peerField.setAccessibilityLabel("远端设备 ID")
        peerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 终端提示符 ❯
        let peerIcon = NSTextField(labelWithString: "❯")
        peerIcon.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        peerIcon.textColor = HomePalette.accent

        let fieldRow = NSStackView(views: [
            peerIcon,
            peerField,
        ])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .centerY
        fieldRow.spacing = 8
        fieldRow.translatesAutoresizingMaskIntoConstraints = false

        peerContainer.wantsLayer = true
        peerContainer.layer?.cornerRadius = 8
        peerContainer.layer?.backgroundColor = NSColor.black
            .withAlphaComponent(0.18).cgColor
        peerContainer.layer?.borderColor = NSColor.white
            .withAlphaComponent(0.14).cgColor
        peerContainer.layer?.borderWidth = 1
        peerContainer.addSubview(fieldRow)
        NSLayoutConstraint.activate([
            fieldRow.leadingAnchor.constraint(equalTo: peerContainer.leadingAnchor, constant: 12),
            fieldRow.trailingAnchor.constraint(equalTo: peerContainer.trailingAnchor, constant: -12),
            fieldRow.topAnchor.constraint(equalTo: peerContainer.topAnchor),
            fieldRow.bottomAnchor.constraint(equalTo: peerContainer.bottomAnchor),
        ])

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectQuickly)

        quickSendFilesButton.bezelStyle = .rounded
        quickSendFilesButton.target = self
        quickSendFilesButton.action = #selector(sendFilesQuickly)
        quickSendFilesButton.toolTip = "连接后立即选择文件或文件夹发送到远端"
        quickSendFilesButton.setAccessibilityLabel("向远端设备发送文件")

        NSLayoutConstraint.activate([
            peerContainer.heightAnchor.constraint(equalToConstant: 34),
            connectButton.widthAnchor.constraint(equalToConstant: 82),
            connectButton.heightAnchor.constraint(equalToConstant: 34),
            quickSendFilesButton.widthAnchor.constraint(equalToConstant: 82),
            quickSendFilesButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        viewerAudioOptInSwitch.target = self
        viewerAudioOptInSwitch.action = #selector(viewerAudioOptInChanged)
        viewerAudioOptInSwitch.setAccessibilityLabel("本次连接接收远端音频")
        let viewerAudioLabel = NSTextField(
            labelWithString: "本次连接接收远端音频（默认关闭，断开后重置）"
        )
        viewerAudioLabel.font = .systemFont(ofSize: 11.5)
        viewerAudioLabel.textColor = .secondaryLabelColor
        let viewerAudioRow = NSStackView(views: [
            viewerAudioLabel,
            NSView(),
            viewerAudioOptInSwitch,
        ])
        viewerAudioRow.orientation = .horizontal
        viewerAudioRow.alignment = .centerY

        // ---------- 本机 Host ----------
        hostStatusDot.wantsLayer = true
        hostStatusDot.layer?.cornerRadius = 3.5
        hostStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostStatusDot.widthAnchor.constraint(equalToConstant: 7),
            hostStatusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        hostStatusLabel.font = .systemFont(ofSize: 12)
        hostStatusLabel.textColor = .secondaryLabelColor

        hostSwitch.target = self
        hostSwitch.action = #selector(hostToggleChanged)
        hostSwitch.setAccessibilityLabel("允许连接此 Mac")

        hostIDLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        hostIDLabel.textColor = HomePalette.accent
        hostIDLabel.lineBreakMode = .byTruncatingMiddle
        hostPasswordLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        hostPasswordLabel.textColor = .labelColor

        hostIDCopyButton.title = "复制"
        hostIDCopyButton.bezelStyle = .inline
        hostIDCopyButton.target = self
        hostIDCopyButton.action = #selector(copyHostID)
        hostIDCopyButton.setAccessibilityLabel("复制本机 ID")
        hostPasswordCopyButton.title = "复制"
        hostPasswordCopyButton.bezelStyle = .inline
        hostPasswordCopyButton.target = self
        hostPasswordCopyButton.action = #selector(copyHostTemporaryPassword)
        hostPasswordCopyButton.setAccessibilityLabel("复制临时密码")

        hostRevealButton.title = "显示"
        hostRevealButton.bezelStyle = .inline
        hostRevealButton.target = self
        hostRevealButton.action = #selector(revealHostPassword)
        hostRegenerateButton.title = "换一个"
        hostRegenerateButton.bezelStyle = .inline
        hostRegenerateButton.target = self
        hostRegenerateButton.action = #selector(regenerateHostPassword)

        let hostIDDetails = NSStackView(views: [
            hostIDLabel,
            NSView(),
            hostIDCopyButton,
        ])
        hostIDDetails.orientation = .horizontal
        hostIDDetails.alignment = .centerY
        hostIDDetails.spacing = 8
        let hostPasswordDetails = NSStackView(views: [
            hostPasswordLabel,
            NSView(),
            hostPasswordCopyButton,
            hostRevealButton,
            hostRegenerateButton,
        ])
        hostPasswordDetails.orientation = .horizontal
        hostPasswordDetails.alignment = .centerY
        hostPasswordDetails.spacing = 8
        hostIDLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostPasswordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        hostCopyFeedbackLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hostCopyFeedbackLabel.textColor = HomePalette.accent
        hostCopyFeedbackLabel.heightAnchor.constraint(equalToConstant: 16).isActive = true

        hostPermanentPasswordLabel.font = .systemFont(ofSize: 12, weight: .regular)
        hostPermanentPasswordLabel.textColor = .secondaryLabelColor
        hostSetPermanentPasswordButton.title = "设置"
        hostSetPermanentPasswordButton.bezelStyle = .inline
        hostSetPermanentPasswordButton.target = self
        hostSetPermanentPasswordButton.action = #selector(setHostPermanentPassword)
        hostClearPermanentPasswordButton.title = "清除"
        hostClearPermanentPasswordButton.bezelStyle = .inline
        hostClearPermanentPasswordButton.target = self
        hostClearPermanentPasswordButton.action = #selector(clearHostPermanentPassword)

        let hostPermanentPasswordDetails = NSStackView(views: [
            hostPermanentPasswordLabel,
            NSView(),
            hostSetPermanentPasswordButton,
            hostClearPermanentPasswordButton,
        ])
        hostPermanentPasswordDetails.orientation = .horizontal
        hostPermanentPasswordDetails.alignment = .centerY
        hostPermanentPasswordDetails.spacing = 12

        let hostClipboardTitle = NSTextField(labelWithString: "剪贴板同步（默认关闭）")
        hostClipboardTitle.font = .systemFont(ofSize: 12, weight: .medium)
        hostClipboardTitle.textColor = .secondaryLabelColor

        let hostClipboardSmallTextTitle = NSTextField(
            labelWithString: "小型文本（最多 64 KiB）"
        )
        hostClipboardSmallTextTitle.font = .systemFont(ofSize: 11)
        hostClipboardSmallTextTitle.textColor = .tertiaryLabelColor

        hostClipboardReadSwitch.target = self
        hostClipboardReadSwitch.action = #selector(hostClipboardReadToggleChanged)
        hostClipboardReadSwitch.setAccessibilityLabel("允许远端读取本机剪贴板")
        let hostClipboardReadLabel = NSTextField(
            labelWithString: "允许远端读取本机剪贴板"
        )
        hostClipboardReadLabel.font = .systemFont(ofSize: 12)
        hostClipboardReadLabel.textColor = .secondaryLabelColor
        let hostClipboardReadRow = NSStackView(views: [
            hostClipboardReadLabel,
            NSView(),
            hostClipboardReadSwitch,
        ])
        hostClipboardReadRow.orientation = .horizontal
        hostClipboardReadRow.alignment = .centerY

        hostClipboardWriteSwitch.target = self
        hostClipboardWriteSwitch.action = #selector(hostClipboardWriteToggleChanged)
        hostClipboardWriteSwitch.setAccessibilityLabel("允许远端写入本机剪贴板")
        let hostClipboardWriteLabel = NSTextField(
            labelWithString: "允许远端写入本机剪贴板"
        )
        hostClipboardWriteLabel.font = .systemFont(ofSize: 12)
        hostClipboardWriteLabel.textColor = .secondaryLabelColor
        let hostClipboardWriteRow = NSStackView(views: [
            hostClipboardWriteLabel,
            NSView(),
            hostClipboardWriteSwitch,
        ])
        hostClipboardWriteRow.orientation = .horizontal
        hostClipboardWriteRow.alignment = .centerY

        let hostClipboardRichTextTitle = NSTextField(
            labelWithString: "富文本 RTF/HTML（每种最多 1 MiB）"
        )
        hostClipboardRichTextTitle.font = .systemFont(ofSize: 11)
        hostClipboardRichTextTitle.textColor = .tertiaryLabelColor

        hostClipboardRichTextReadSwitch.target = self
        hostClipboardRichTextReadSwitch.action =
            #selector(hostClipboardRichTextReadToggleChanged)
        hostClipboardRichTextReadSwitch.setAccessibilityLabel(
            "允许远端读取本机富文本"
        )
        let hostClipboardRichTextReadLabel = NSTextField(
            labelWithString: "允许远端读取本机富文本"
        )
        hostClipboardRichTextReadLabel.font = .systemFont(ofSize: 12)
        hostClipboardRichTextReadLabel.textColor = .secondaryLabelColor
        let hostClipboardRichTextReadRow = NSStackView(views: [
            hostClipboardRichTextReadLabel,
            NSView(),
            hostClipboardRichTextReadSwitch,
        ])
        hostClipboardRichTextReadRow.orientation = .horizontal
        hostClipboardRichTextReadRow.alignment = .centerY

        hostClipboardRichTextWriteSwitch.target = self
        hostClipboardRichTextWriteSwitch.action =
            #selector(hostClipboardRichTextWriteToggleChanged)
        hostClipboardRichTextWriteSwitch.setAccessibilityLabel(
            "允许远端写入本机富文本"
        )
        let hostClipboardRichTextWriteLabel = NSTextField(
            labelWithString: "允许远端写入本机富文本"
        )
        hostClipboardRichTextWriteLabel.font = .systemFont(ofSize: 12)
        hostClipboardRichTextWriteLabel.textColor = .secondaryLabelColor
        let hostClipboardRichTextWriteRow = NSStackView(views: [
            hostClipboardRichTextWriteLabel,
            NSView(),
            hostClipboardRichTextWriteSwitch,
        ])
        hostClipboardRichTextWriteRow.orientation = .horizontal
        hostClipboardRichTextWriteRow.alignment = .centerY

        let hostClipboardImageTitle = NSTextField(
            labelWithString: "图片（RGBA/PNG 最多 128 MiB，SVG 最多 4 MiB）"
        )
        hostClipboardImageTitle.font = .systemFont(ofSize: 11)
        hostClipboardImageTitle.textColor = .tertiaryLabelColor

        hostClipboardImageReadSwitch.target = self
        hostClipboardImageReadSwitch.action =
            #selector(hostClipboardImageReadToggleChanged)
        hostClipboardImageReadSwitch.setAccessibilityLabel(
            "允许远端读取本机图片"
        )
        let hostClipboardImageReadLabel = NSTextField(
            labelWithString: "允许远端读取本机图片"
        )
        hostClipboardImageReadLabel.font = .systemFont(ofSize: 12)
        hostClipboardImageReadLabel.textColor = .secondaryLabelColor
        let hostClipboardImageReadRow = NSStackView(views: [
            hostClipboardImageReadLabel,
            NSView(),
            hostClipboardImageReadSwitch,
        ])
        hostClipboardImageReadRow.orientation = .horizontal
        hostClipboardImageReadRow.alignment = .centerY

        hostClipboardImageWriteSwitch.target = self
        hostClipboardImageWriteSwitch.action =
            #selector(hostClipboardImageWriteToggleChanged)
        hostClipboardImageWriteSwitch.setAccessibilityLabel(
            "允许远端写入图片到本机"
        )
        let hostClipboardImageWriteLabel = NSTextField(
            labelWithString: "允许远端写入图片到本机"
        )
        hostClipboardImageWriteLabel.font = .systemFont(ofSize: 12)
        hostClipboardImageWriteLabel.textColor = .secondaryLabelColor
        let hostClipboardImageWriteRow = NSStackView(views: [
            hostClipboardImageWriteLabel,
            NSView(),
            hostClipboardImageWriteSwitch,
        ])
        hostClipboardImageWriteRow.orientation = .horizontal
        hostClipboardImageWriteRow.alignment = .centerY

        let hostClipboardSettings = NSStackView(views: [
            hostClipboardSmallTextTitle,
            hostClipboardReadRow,
            hostClipboardWriteRow,
            hostClipboardRichTextTitle,
            hostClipboardRichTextReadRow,
            hostClipboardRichTextWriteRow,
            hostClipboardImageTitle,
            hostClipboardImageReadRow,
            hostClipboardImageWriteRow,
        ])
        hostClipboardSettings.orientation = .vertical
        hostClipboardSettings.alignment = .leading
        hostClipboardSettings.spacing = 5
        for view in [
            hostClipboardReadRow,
            hostClipboardWriteRow,
            hostClipboardRichTextReadRow,
            hostClipboardRichTextWriteRow,
            hostClipboardImageReadRow,
            hostClipboardImageWriteRow,
        ] {
            view.widthAnchor.constraint(
                equalTo: hostClipboardSettings.widthAnchor
            ).isActive = true
        }

        let hostFileTransferTitle = NSTextField(
            labelWithString: "文件接收（默认关闭）"
        )
        hostFileTransferTitle.font = .systemFont(ofSize: 12, weight: .medium)
        hostFileTransferTitle.textColor = .secondaryLabelColor
        hostFileTransferSwitch.target = self
        hostFileTransferSwitch.action = #selector(hostFileTransferToggleChanged)
        hostFileTransferSwitch.setAccessibilityLabel("允许远端发送文件到本机")
        let hostFileTransferToggleLabel = NSTextField(
            labelWithString: "允许远端发送文件到本机"
        )
        hostFileTransferToggleLabel.font = .systemFont(ofSize: 12)
        hostFileTransferToggleLabel.textColor = .secondaryLabelColor
        let hostFileTransferToggleRow = NSStackView(views: [
            hostFileTransferToggleLabel,
            NSView(),
            hostFileTransferSwitch,
        ])
        hostFileTransferToggleRow.orientation = .horizontal
        hostFileTransferToggleRow.alignment = .centerY

        hostFileTransferReceiveRootLabel.font = .systemFont(ofSize: 11)
        hostFileTransferReceiveRootLabel.textColor = .tertiaryLabelColor
        hostFileTransferReceiveRootLabel.lineBreakMode = .byTruncatingMiddle
        hostFileTransferReceiveRootButton.bezelStyle = .inline
        hostFileTransferReceiveRootButton.target = self
        hostFileTransferReceiveRootButton.action =
            #selector(chooseHostFileTransferReceiveRoot)
        hostFileTransferReceiveRootButton.setAccessibilityLabel(
            "选择 FarPane Receive 接收文件夹的位置"
        )
        let hostFileTransferRootRow = NSStackView(views: [
            hostFileTransferReceiveRootLabel,
            NSView(),
            hostFileTransferReceiveRootButton,
        ])
        hostFileTransferRootRow.orientation = .horizontal
        hostFileTransferRootRow.alignment = .centerY

        let hostFileTransferSettings = NSStackView(views: [
            hostFileTransferToggleRow,
            hostFileTransferRootRow,
        ])
        hostFileTransferSettings.orientation = .vertical
        hostFileTransferSettings.alignment = .leading
        hostFileTransferSettings.spacing = 5
        for view in [
            hostFileTransferToggleRow,
            hostFileTransferRootRow,
        ] {
            view.widthAnchor.constraint(
                equalTo: hostFileTransferSettings.widthAnchor
            ).isActive = true
        }

        let hostAudioTitle = NSTextField(
            labelWithString: "远程音频（默认关闭）"
        )
        hostAudioTitle.font = .systemFont(ofSize: 12, weight: .medium)
        hostAudioTitle.textColor = .secondaryLabelColor
        hostAudioSwitch.target = self
        hostAudioSwitch.action = #selector(hostAudioToggleChanged)
        hostAudioSwitch.setAccessibilityLabel("允许远端接收本机音频")
        let hostAudioToggleLabel = NSTextField(
            labelWithString: "允许远端接收本机音频"
        )
        hostAudioToggleLabel.font = .systemFont(ofSize: 12)
        hostAudioToggleLabel.textColor = .secondaryLabelColor
        let hostAudioToggleRow = NSStackView(views: [
            hostAudioToggleLabel,
            NSView(),
            hostAudioSwitch,
        ])
        hostAudioToggleRow.orientation = .horizontal
        hostAudioToggleRow.alignment = .centerY
        hostAudioInputPopup.target = self
        hostAudioInputPopup.action = #selector(hostAudioInputSelectionChanged)
        hostAudioInputPopup.setAccessibilityLabel("选择远程音频输入设备")
        hostAudioInputRefreshButton.title = "刷新"
        hostAudioInputRefreshButton.bezelStyle = .inline
        hostAudioInputRefreshButton.target = self
        hostAudioInputRefreshButton.action = #selector(refreshHostAudioInputs)
        hostAudioInputRefreshButton.setAccessibilityLabel("刷新音频输入设备")
        let hostAudioInputLabel = NSTextField(labelWithString: "音频输入")
        hostAudioInputLabel.font = .systemFont(ofSize: 12)
        hostAudioInputLabel.textColor = .secondaryLabelColor
        let hostAudioInputRow = NSStackView(views: [
            hostAudioInputLabel,
            NSView(),
            hostAudioInputPopup,
            hostAudioInputRefreshButton,
        ])
        hostAudioInputRow.orientation = .horizontal
        hostAudioInputRow.alignment = .centerY
        hostAudioInputStatusLabel.font = .systemFont(ofSize: 11)
        hostAudioInputStatusLabel.textColor = .tertiaryLabelColor
        hostMicrophoneAuthorizationLabel.font = .systemFont(ofSize: 11)
        hostMicrophoneAuthorizationLabel.textColor = .tertiaryLabelColor
        let hostAudioSettings = NSStackView(views: [
            hostAudioToggleRow,
            hostAudioInputRow,
            hostAudioInputStatusLabel,
            hostMicrophoneAuthorizationLabel,
        ])
        hostAudioSettings.orientation = .vertical
        hostAudioSettings.alignment = .leading
        hostAudioSettings.spacing = 5
        for view in [
            hostAudioToggleRow,
            hostAudioInputRow,
            hostAudioInputStatusLabel,
            hostMicrophoneAuthorizationLabel,
        ] {
            view.widthAnchor.constraint(
                equalTo: hostAudioSettings.widthAnchor
            ).isActive = true
        }

        hostSessionContainer.wantsLayer = true
        hostSessionContainer.layer?.cornerRadius = 9
        hostSessionContainer.layer?.backgroundColor = NSColor.systemBlue
            .withAlphaComponent(0.07).cgColor
        hostSessionContainer.layer?.borderColor = NSColor.systemBlue
            .withAlphaComponent(0.4).cgColor
        hostSessionContainer.layer?.borderWidth = 1
        hostSessionContainer.isHidden = true

        hostSessionTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hostSessionTitleLabel.textColor = .labelColor
        hostSessionIdentityLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        hostSessionIdentityLabel.textColor = .labelColor
        hostSessionContextLabel.font = .systemFont(ofSize: 11.5)
        hostSessionContextLabel.textColor = .secondaryLabelColor
        hostSessionCapabilityLabel.font = .systemFont(ofSize: 11.5)
        hostSessionCapabilityLabel.textColor = .secondaryLabelColor

        hostDisableInputButton.title = "停止键鼠控制"
        hostDisableInputButton.bezelStyle = .rounded
        hostDisableInputButton.target = self
        hostDisableInputButton.action = #selector(disableHostSessionInput)
        hostDisableInputButton.setAccessibilityLabel("停止当前会话的键盘与鼠标控制")
        hostDisableClipboardReadButton.title = "停止远端读取"
        hostDisableClipboardReadButton.bezelStyle = .rounded
        hostDisableClipboardReadButton.target = self
        hostDisableClipboardReadButton.action = #selector(disableHostSessionClipboardRead)
        hostDisableClipboardReadButton.setAccessibilityLabel(
            "停止当前会话读取本机剪贴板"
        )
        hostDisableClipboardWriteButton.title = "停止远端写入"
        hostDisableClipboardWriteButton.bezelStyle = .rounded
        hostDisableClipboardWriteButton.target = self
        hostDisableClipboardWriteButton.action = #selector(disableHostSessionClipboardWrite)
        hostDisableClipboardWriteButton.setAccessibilityLabel(
            "停止当前会话写入本机剪贴板"
        )
        hostDisableAudioButton.title = "停止系统音频"
        hostDisableAudioButton.bezelStyle = .rounded
        hostDisableAudioButton.target = self
        hostDisableAudioButton.action = #selector(disableHostSessionAudio)
        hostDisableAudioButton.setAccessibilityLabel("停止当前会话的系统音频")
        hostDisconnectButton.title = "断开连接"
        hostDisconnectButton.bezelStyle = .rounded
        hostDisconnectButton.contentTintColor = .systemRed
        hostDisconnectButton.target = self
        hostDisconnectButton.action = #selector(disconnectHostSession)
        hostDisconnectButton.setAccessibilityLabel("断开当前远程会话")

        let hostSessionButtons = NSStackView(views: [
            NSView(),
            hostDisableInputButton,
            hostDisableClipboardReadButton,
            hostDisableClipboardWriteButton,
            hostDisableAudioButton,
            hostDisconnectButton,
        ])
        hostSessionButtons.orientation = .horizontal
        hostSessionButtons.alignment = .centerY
        hostSessionButtons.spacing = 8
        let hostSessionStack = NSStackView(views: [
            hostSessionTitleLabel,
            hostSessionIdentityLabel,
            hostSessionContextLabel,
            hostSessionCapabilityLabel,
            hostSessionButtons,
        ])
        hostSessionStack.orientation = .vertical
        hostSessionStack.alignment = .leading
        hostSessionStack.spacing = 5
        for view in [
            hostSessionTitleLabel,
            hostSessionIdentityLabel,
            hostSessionContextLabel,
            hostSessionCapabilityLabel,
            hostSessionButtons,
        ] {
            view.widthAnchor.constraint(equalTo: hostSessionStack.widthAnchor).isActive = true
        }
        hostSessionContainer.addSubview(hostSessionStack)
        hostSessionStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostSessionStack.leadingAnchor.constraint(
                equalTo: hostSessionContainer.leadingAnchor,
                constant: 12
            ),
            hostSessionStack.trailingAnchor.constraint(
                equalTo: hostSessionContainer.trailingAnchor,
                constant: -12
            ),
            hostSessionStack.topAnchor.constraint(
                equalTo: hostSessionContainer.topAnchor,
                constant: 10
            ),
            hostSessionStack.bottomAnchor.constraint(
                equalTo: hostSessionContainer.bottomAnchor,
                constant: -10
            ),
        ])

        hostApprovalContainer.wantsLayer = true
        hostApprovalContainer.layer?.cornerRadius = 9
        hostApprovalContainer.layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.08).cgColor
        hostApprovalContainer.layer?.borderColor = NSColor.systemOrange
            .withAlphaComponent(0.45).cgColor
        hostApprovalContainer.layer?.borderWidth = 1
        hostApprovalContainer.isHidden = true

        hostApprovalTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        hostApprovalTitleLabel.textColor = .labelColor
        hostApprovalIdentityLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        hostApprovalIdentityLabel.textColor = .labelColor
        hostApprovalContextLabel.font = .systemFont(ofSize: 11.5)
        hostApprovalContextLabel.textColor = .secondaryLabelColor
        hostApprovalCapabilityLabel.font = .systemFont(ofSize: 11.5)
        hostApprovalCapabilityLabel.textColor = .secondaryLabelColor
        hostApprovalExpiryLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        hostApprovalExpiryLabel.textColor = .systemOrange

        hostApproveButton.title = "允许一次"
        hostApproveButton.bezelStyle = .rounded
        hostApproveButton.target = self
        hostApproveButton.action = #selector(approveHostConnection)
        hostApproveButton.setAccessibilityLabel("允许远程连接一次")
        hostRejectButton.title = "拒绝"
        hostRejectButton.bezelStyle = .rounded
        hostRejectButton.target = self
        hostRejectButton.action = #selector(rejectHostConnection)
        hostRejectButton.setAccessibilityLabel("拒绝远程连接")

        let hostApprovalButtons = NSStackView(views: [NSView(), hostRejectButton, hostApproveButton])
        hostApprovalButtons.orientation = .horizontal
        hostApprovalButtons.alignment = .centerY
        hostApprovalButtons.spacing = 8
        let hostApprovalStack = NSStackView(views: [
            hostApprovalTitleLabel,
            hostApprovalIdentityLabel,
            hostApprovalContextLabel,
            hostApprovalCapabilityLabel,
            hostApprovalExpiryLabel,
            hostApprovalButtons,
        ])
        hostApprovalStack.orientation = .vertical
        hostApprovalStack.alignment = .leading
        hostApprovalStack.spacing = 5
        for view in [
            hostApprovalTitleLabel,
            hostApprovalIdentityLabel,
            hostApprovalContextLabel,
            hostApprovalCapabilityLabel,
            hostApprovalExpiryLabel,
            hostApprovalButtons,
        ] {
            view.widthAnchor.constraint(equalTo: hostApprovalStack.widthAnchor).isActive = true
        }
        hostApprovalContainer.addSubview(hostApprovalStack)
        hostApprovalStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostApprovalStack.leadingAnchor.constraint(
                equalTo: hostApprovalContainer.leadingAnchor,
                constant: 12
            ),
            hostApprovalStack.trailingAnchor.constraint(
                equalTo: hostApprovalContainer.trailingAnchor,
                constant: -12
            ),
            hostApprovalStack.topAnchor.constraint(
                equalTo: hostApprovalContainer.topAnchor,
                constant: 10
            ),
            hostApprovalStack.bottomAnchor.constraint(
                equalTo: hostApprovalContainer.bottomAnchor,
                constant: -10
            ),
        ])

        hostMediaDiagnosticLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        hostMediaDiagnosticLabel.textColor = .secondaryLabelColor
        hostMediaDiagnosticLabel.isHidden = true

        hostErrorLabel.textColor = .systemOrange
        hostErrorLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        hostErrorLabel.isHidden = true

        hostCommandRetryButton.title = "重试操作"
        hostCommandRetryButton.bezelStyle = .rounded
        hostCommandRetryButton.target = self
        hostCommandRetryButton.action = #selector(retryHostCommand)
        hostCommandRetryButton.isHidden = true

        // ---------- 快速连接与被控 Host ----------
        let hostToggleTitle = NSTextField(labelWithString: "被控 Host")
        hostToggleTitle.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        hostToggleTitle.textColor = .tertiaryLabelColor
        hostStatusLabel.lineBreakMode = .byTruncatingTail
        hostStatusLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let connectionRow = NSStackView(views: [
            peerContainer,
            connectButton,
            quickSendFilesButton,
        ])
        connectionRow.orientation = .horizontal
        connectionRow.alignment = .centerY
        connectionRow.spacing = 8

        let connectionColumn = NSStackView(views: [connectionRow, viewerAudioRow])
        connectionColumn.orientation = .vertical
        connectionColumn.alignment = .leading
        connectionColumn.spacing = 8
        connectionRow.widthAnchor.constraint(
            equalTo: connectionColumn.widthAnchor
        ).isActive = true
        viewerAudioRow.widthAnchor.constraint(
            equalTo: connectionColumn.widthAnchor
        ).isActive = true

        let quickDivider = NSView()
        quickDivider.wantsLayer = true
        quickDivider.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(0.10).cgColor
        NSLayoutConstraint.activate([
            quickDivider.widthAnchor.constraint(equalToConstant: 1),
            quickDivider.heightAnchor.constraint(equalToConstant: 46),
        ])

        let hostToggleRow = NSStackView(views: [
            hostToggleTitle,
            hostStatusDot,
            hostStatusLabel,
            NSView(),
            hostSwitch,
        ])
        hostToggleRow.orientation = .horizontal
        hostToggleRow.alignment = .centerY
        hostToggleRow.spacing = 8

        let quickCard = NSStackView(views: [
            connectionColumn,
            quickDivider,
            hostToggleRow,
        ])
        quickCard.orientation = .horizontal
        quickCard.alignment = .centerY
        quickCard.spacing = 14
        connectionColumn.widthAnchor.constraint(
            equalTo: quickCard.widthAnchor,
            multiplier: 0.62
        ).isActive = true
        hostToggleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let quickContainer = makePanel(content: quickCard)

        // ---------- 本机概览：三张迷你卡 ----------
        let hostIDCard = makeHostMiniCard(title: "本机 ID", content: hostIDDetails)
        let hostPasswordCard = makeHostMiniCard(title: "临时密码", content: hostPasswordDetails)
        let hostPermanentCard = makeHostMiniCard(title: "永久密码", content: hostPermanentPasswordDetails)

        let hostStrip = NSStackView(views: [
            hostIDCard,
            hostPasswordCard,
            hostPermanentCard,
        ])
        hostStrip.orientation = .horizontal
        hostStrip.alignment = .top
        hostStrip.distribution = .fillEqually
        hostStrip.spacing = 8

        // ---------- 系统授权 chip 条 ----------
        let permissionBarTitle = NSTextField(labelWithString: "系统授权")
        permissionBarTitle.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        permissionBarTitle.textColor = .tertiaryLabelColor
        permissionChipsLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        permissionChipsLabel.stringValue = "正在检测…"
        let permissionRefreshButton = NSButton(
            title: "重新检测",
            target: self,
            action: #selector(refreshSystemPermissions)
        )
        permissionRefreshButton.bezelStyle = .inline
        permissionRefreshButton.setAccessibilityLabel("重新检测系统授权状态")
        let permissionManageButton = NSButton(
            title: "管理",
            target: self,
            action: #selector(openPermissionsPage)
        )
        permissionManageButton.bezelStyle = .inline
        permissionManageButton.setAccessibilityLabel("打开授权与安全页面")
        let permissionBarRow = NSStackView(views: [
            permissionBarTitle,
            permissionChipsLabel,
            NSView(),
            permissionRefreshButton,
            permissionManageButton,
        ])
        permissionBarRow.orientation = .horizontal
        permissionBarRow.alignment = .centerY
        permissionBarRow.spacing = 10
        let permissionBar = makePanel(
            content: permissionBarRow,
            insets: NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        )

        // ---------- Host 动态横幅（会话 / 审批 / 错误，默认隐藏） ----------
        let hostBanner = NSStackView(views: [
            hostCopyFeedbackLabel,
            hostSessionContainer,
            hostApprovalContainer,
            hostMediaDiagnosticLabel,
            hostErrorLabel,
            hostCommandRetryButton,
        ])
        hostBanner.orientation = .vertical
        hostBanner.alignment = .leading
        hostBanner.spacing = 8
        for view in hostBanner.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: hostBanner.widthAnchor).isActive = true
        }

        let clipboardSection = makeSettingsSection(
            symbolName: "doc.on.clipboard",
            title: "剪贴板同步",
            detail: "按数据类型和方向分别控制",
            content: hostClipboardSettings
        )
        let audioSection = makeSettingsSection(
            symbolName: "waveform",
            title: "远程音频",
            detail: "默认关闭，原生捕获系统音频",
            content: hostAudioSettings
        )
        let fileSection = makeSettingsSection(
            symbolName: "folder",
            title: "文件接收",
            detail: "限定接收根目录并逐次确认",
            content: hostFileTransferSettings
        )
        let sharingCard = NSStackView(views: [
            clipboardSection,
            makeSeparator(),
            audioSection,
            makeSeparator(),
            fileSection,
        ])
        sharingCard.orientation = .vertical
        sharingCard.alignment = .leading
        sharingCard.spacing = 16
        for view in sharingCard.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sharingCard.widthAnchor).isActive = true
        }
        let sharingContainer = makePanel(content: sharingCard)

        // ---------- 列表工具栏 ----------
        let recentTitle = NSTextField(labelWithString: "最近连接")
        recentTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        countBadge.font = .systemFont(ofSize: 12, weight: .semibold)
        countBadge.textColor = .tertiaryLabelColor
        countBadge.alignment = .center
        countBadge.wantsLayer = true
        countBadge.layer?.cornerRadius = 9
        countBadge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.16).cgColor
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            countBadge.heightAnchor.constraint(equalToConstant: 18),
        ])

        let recentWrap = NSStackView(views: [recentTitle, countBadge])
        recentWrap.orientation = .horizontal
        recentWrap.alignment = .centerY
        recentWrap.spacing = 6

        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        searchField.placeholderString = "搜索名称或 ID"
        searchField.delegate = self
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let listToolbar = NSStackView(views: [recentWrap, NSView(), filterControl, searchField])
        listToolbar.orientation = .horizontal
        listToolbar.alignment = .centerY
        listToolbar.spacing = 12

        // ---------- 设备列表 ----------
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = listStack
        NSLayoutConstraint.activate([
            listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        // ---------- 错误提示 ----------
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.isHidden = true

        // ---------- 侧栏状态 ----------
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        let versionText: String
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            versionText = "v\(version)"
        } else {
            versionText = ""
        }
        let versionLabel = NSTextField(labelWithString: versionText)
        versionLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        versionLabel.textColor = .tertiaryLabelColor

        // ---------- 真正的页面切换 ----------
        let connectionsContent = NSStackView(views: [
            makePageHeader(
                title: "设备",
                subtitle: "输入远端 ID 发起连接，或从最近连接快速返回。"
            ),
            quickContainer,
            hostStrip,
            permissionBar,
            hostBanner,
            listToolbar,
            errorLabel,
            scrollView,
        ])
        connectionsContent.orientation = .vertical
        connectionsContent.alignment = .leading
        connectionsContent.spacing = 12
        connectionsContent.setCustomSpacing(16, after: connectionsContent.arrangedSubviews[0])
        connectionsContent.setCustomSpacing(8, after: listToolbar)
        for view in connectionsContent.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: connectionsContent.widthAnchor).isActive = true
        }
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let connectionsPage = makePage(content: connectionsContent, scrolls: false)

        let permissionContainer = makePermissionsPanel()
        let permissionsPage = makeScrollablePage(views: [
            makePageHeader(
                title: "授权与安全",
                subtitle: "读取 macOS 权威状态，并直接打开对应的系统设置页面。"
            ),
            permissionContainer,
        ])

        let settingsPage = makeScrollablePage(views: [
            makePageHeader(
                title: "共享设置",
                subtitle: "决定远端会话可以使用哪些本机能力；未开启的能力保持关闭。"
            ),
            sharingContainer,
        ])

        pageTabView.tabViewType = .noTabsNoBorder
        pageTabView.drawsBackground = false
        for (page, view) in [
            (HomePage.connections, connectionsPage),
            (.permissions, permissionsPage),
            (.sharing, settingsPage),
        ] {
            let item = NSTabViewItem(identifier: page.rawValue)
            item.label = page.title
            item.view = view
            pageTabView.addTabViewItem(item)
        }

        let sidebar = makeSidebar(versionLabel: versionLabel)
        let root = NSStackView(views: [sidebar, pageTabView])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208),
            sidebar.heightAnchor.constraint(equalTo: root.heightAnchor),
            pageTabView.widthAnchor.constraint(
                equalTo: root.widthAnchor,
                constant: -208
            ),
            pageTabView.heightAnchor.constraint(equalTo: root.heightAnchor),
        ])
        selectPage(.connections)
    }

    private func makeSidebar(versionLabel: NSTextField) -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active

        let brand = NSStackView(views: [BrandLogoView(), brandNameLabel()])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 10

        let navigation = NSStackView()
        navigation.orientation = .vertical
        navigation.alignment = .leading
        navigation.spacing = 4
        navigation.addArrangedSubview(sidebarSectionLabel("工作台"))
        for page in HomePage.allCases {
            let button = HomeSidebarButton(page: page)
            button.target = self
            button.action = #selector(sidebarPageChanged(_:))
            sidebarButtons[page] = button
            navigation.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
        }

        let serverTitle = sidebarSectionLabel("系统")
        let serverWrap = NSStackView(views: [serverStatusDot, serverButton])
        serverWrap.orientation = .horizontal
        serverWrap.alignment = .centerY
        serverWrap.spacing = 4
        serverWrap.wantsLayer = true
        serverWrap.layer?.cornerRadius = 9
        serverWrap.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(0.035).cgColor
        serverWrap.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)

        let statusWrap = NSStackView(views: [statusDot, statusLabel, NSView(), versionLabel])
        statusWrap.orientation = .horizontal
        statusWrap.alignment = .centerY
        statusWrap.spacing = 7

        let separator = makeSeparator()
        let stack = NSStackView(views: [
            brand,
            navigation,
            serverTitle,
            serverWrap,
            NSView(),
            separator,
            statusWrap,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(28, after: brand)
        stack.setCustomSpacing(22, after: navigation)
        stack.setCustomSpacing(7, after: serverTitle)
        for view in [brand, navigation, serverTitle, serverWrap, separator, statusWrap] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        sidebar.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
        ])
        return sidebar
    }

    private func sidebarSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makePageHeader(
        title: String,
        subtitle: String
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func makePage(content: NSView, scrolls: Bool) -> NSView {
        if scrolls { return makeScrollablePage(views: [content]) }
        let page = NSView()
        page.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 34),
            content.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -34),
            content.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            content.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24),
        ])
        return page
    }

    private func makeScrollablePage(views: [NSView]) -> NSView {
        let content = FlippedStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        if let first = views.first {
            content.setCustomSpacing(26, after: first)
        }
        for view in views {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        let document = FlippedView()
        document.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 34),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -34),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 30),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -40),
        ])

        let page = NSView()
        page.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: page.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor),
        ])
        return page
    }

    private func makePanel(
        content: NSView,
        emphasized: Bool = false,
        cornerRadius: CGFloat = 10,
        insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    ) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = cornerRadius
        panel.layer?.backgroundColor = HomePalette.panel.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = (emphasized
            ? HomePalette.accent.withAlphaComponent(0.24)
            : NSColor.white.withAlphaComponent(0.12)).cgColor
        panel.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -insets.bottom),
        ])
        return panel
    }

    /// 概览迷你卡：mono 小标题 + 内容行
    private func makeHostMiniCard(title: String, content: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        titleLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(views: [titleLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return makePanel(
            content: stack,
            insets: NSEdgeInsets(top: 9, left: 12, bottom: 10, right: 12)
        )
    }

    private func makeSettingsSection(
        symbolName: String,
        title: String,
        detail: String,
        content: NSView
    ) -> NSView {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: title
        ) ?? NSImage())
        icon.contentTintColor = HomePalette.accent
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
        ])
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 10.5)
        detailLabel.textColor = .tertiaryLabelColor
        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3
        let header = NSStackView(views: [icon, copy, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        let section = NSStackView(views: [header, content])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 13
        header.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    private func makePermissionsPanel() -> NSView {
        permissionSummaryLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        permissionSummaryDetailLabel.font = .systemFont(ofSize: 11)
        permissionSummaryDetailLabel.textColor = .secondaryLabelColor
        let summaryCopy = NSStackView(views: [
            permissionSummaryLabel,
            permissionSummaryDetailLabel,
        ])
        summaryCopy.orientation = .vertical
        summaryCopy.alignment = .leading
        summaryCopy.spacing = 4
        let refreshButton = NSButton(
            title: "重新检测",
            target: self,
            action: #selector(refreshSystemPermissions)
        )
        refreshButton.bezelStyle = .rounded
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: nil
        )
        refreshButton.imagePosition = .imageLeading
        let summary = NSStackView(views: [summaryCopy, NSView(), refreshButton])
        summary.orientation = .horizontal
        summary.alignment = .centerY
        summary.spacing = 12

        let stack = NSStackView(views: [summary, makeSeparator()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        for kind in HomeSystemPermissionKind.allCases {
            let row = HomePermissionRowView(kind: kind)
            row.onOpenSettings = { [weak self] kind in
                self?.onOpenSystemPermissionSettings?(kind)
            }
            permissionRows[kind] = row
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(makeSeparator())
        }
        if let trailingSeparator = stack.arrangedSubviews.last {
            stack.removeArrangedSubview(trailingSeparator)
            trailingSeparator.removeFromSuperview()
        }
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return makePanel(content: stack)
    }

    private func makeSeparator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white
            .withAlphaComponent(0.065).cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private func selectPage(_ page: HomePage) {
        selectedPage = page
        pageTabView.selectTabViewItem(withIdentifier: page.rawValue)
        for (candidate, button) in sidebarButtons {
            button.isSelected = candidate == page
        }
        if page == .connections {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedPage == .connections else { return }
                self.window?.makeFirstResponder(self.peerField)
            }
        }
    }

    @objc private func sidebarPageChanged(_ sender: HomeSidebarButton) {
        selectPage(sender.page)
    }

    @objc private func openPermissionsPage() { selectPage(.permissions) }

    @objc private func refreshSystemPermissions() {
        onRefreshSystemPermissions?()
    }

    private func brandNameLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "FarPane")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === peerField {
            let hasID = !peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            connectButton.isEnabled = hasID
                && snapshot.server?.isComplete == true
                && snapshot.connectingPeerID == nil
        } else {
            renderDevices()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        if notification.object as? NSTextField === peerField {
            updatePeerFocus(true)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === peerField {
            updatePeerFocus(false)
        }
    }

    private func updatePeerFocus(_ focused: Bool) {
        guard let layer = peerContainer.layer else { return }
        layer.borderColor = (focused
            ? HomePalette.accent.withAlphaComponent(0.55)
            : NSColor.white.withAlphaComponent(0.14)).cgColor
        layer.shadowColor = HomePalette.accent.cgColor
        layer.shadowOpacity = focused ? 0.25 : 0
        layer.shadowRadius = 5
        layer.shadowOffset = .zero
    }

    private func renderDevices() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let favoritesOnly = filterControl.selectedSegment == 1
        let items = snapshot.devices.filter { item in
            guard !favoritesOnly || item.device.isFavorite else { return false }
            guard !query.isEmpty else { return true }
            return item.device.resolvedDisplayName.localizedCaseInsensitiveContains(query)
                || item.device.peerID.localizedCaseInsensitiveContains(query)
        }

        if items.isEmpty {
            let message: String
            if !query.isEmpty { message = "没有匹配设备" }
            else if favoritesOnly { message = "还没有收藏设备" }
            else { message = "还没有最近连接，输入对方设备 ID 开始连接。" }
            let label = NSTextField(wrappingLabelWithString: message)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.font = .systemFont(ofSize: 14)
            let icon = NSImageView(image: NSImage(
                systemSymbolName: "desktopcomputer",
                accessibilityDescription: nil
            ) ?? NSImage())
            icon.contentTintColor = .tertiaryLabelColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            let container = NSView()
            container.addSubview(label)
            container.addSubview(icon)
            label.translatesAutoresizingMaskIntoConstraints = false
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -16),
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 190),
            ])
            listStack.addArrangedSubview(container)
            container.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return
        }

        for item in items {
            let row = DeviceRowView(
                item: item,
                isConnecting: snapshot.connectingPeerID == item.device.peerID
            )
            row.onAction = { [weak self] action in
                self?.onDeviceAction?(item.device.id, action)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    @objc private func connectQuickly() {
        performQuickAction(onQuickConnect)
    }

    @objc private func sendFilesQuickly() {
        performQuickAction(onQuickSendFiles)
    }

    private func performQuickAction(_ action: ((String) -> Void)?) {
        let peerID = peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty,
              snapshot.server?.isComplete == true,
              snapshot.connectingPeerID == nil else { return }
        action?(peerID)
    }

    @objc private func openServerSettings() { onOpenServerSettings?() }

    @objc private func viewerAudioOptInChanged() {
        guard snapshot.connectingPeerID == nil else { return }
        onViewerAudioOptInToggle?(viewerAudioOptInSwitch.state == .on)
    }

    @objc private func hostToggleChanged() { onHostToggle?(hostSwitch.state == .on) }

    @objc private func hostClipboardReadToggleChanged() {
        guard snapshot.host.allowsClipboardPolicyChange else { return }
        onHostClipboardReadToggle?(hostClipboardReadSwitch.state == .on)
    }

    @objc private func hostClipboardWriteToggleChanged() {
        guard snapshot.host.allowsClipboardPolicyChange else { return }
        onHostClipboardWriteToggle?(hostClipboardWriteSwitch.state == .on)
    }

    @objc private func hostClipboardRichTextReadToggleChanged() {
        guard snapshot.host.allowsClipboardPolicyChange else { return }
        onHostClipboardRichTextReadToggle?(
            hostClipboardRichTextReadSwitch.state == .on
        )
    }

    @objc private func hostClipboardRichTextWriteToggleChanged() {
        guard snapshot.host.allowsClipboardPolicyChange else { return }
        onHostClipboardRichTextWriteToggle?(
            hostClipboardRichTextWriteSwitch.state == .on
        )
    }

    @objc private func hostClipboardImageReadToggleChanged() {
        guard snapshot.host.allowsClipboardPolicyChange else { return }
        onHostClipboardImageReadToggle?(
            hostClipboardImageReadSwitch.state == .on
        )
    }

    @objc private func hostClipboardImageWriteToggleChanged() {
        guard snapshot.host.allowsClipboardPolicyChange else { return }
        onHostClipboardImageWriteToggle?(
            hostClipboardImageWriteSwitch.state == .on
        )
    }

    @objc private func hostFileTransferToggleChanged() {
        guard snapshot.host.allowsFileTransferPolicyChange else { return }
        onHostFileTransferToggle?(hostFileTransferSwitch.state == .on)
    }

    @objc private func hostAudioToggleChanged() {
        guard snapshot.host.allowsAudioPolicyChange else { return }
        onHostAudioToggle?(hostAudioSwitch.state == .on)
    }

    @objc private func hostAudioInputSelectionChanged() {
        guard snapshot.host.allowsAudioPolicyChange,
              let value = hostAudioInputPopup.selectedItem?
                .representedObject as? String
        else { return }
        onHostAudioInputSelection?(value.isEmpty ? nil : value)
    }

    private func applyHostAudioInputSelection(_ host: HostHomeSnapshot) {
        hostAudioInputPopup.removeAllItems()
        hostAudioInputPopup.addItem(withTitle: "系统音频（原生）")
        hostAudioInputPopup.lastItem?.representedObject = ""
        for name in host.audioInputDeviceNames {
            hostAudioInputPopup.addItem(withTitle: name)
            hostAudioInputPopup.lastItem?.representedObject = name
        }
        if let selected = host.audioInputDeviceName,
           !host.audioInputDeviceNames.contains(selected) {
            hostAudioInputPopup.addItem(withTitle: "不可用：\(selected)")
            hostAudioInputPopup.lastItem?.representedObject = selected
        }
        let representedValue = host.audioInputDeviceName ?? ""
        if let item = hostAudioInputPopup.itemArray.first(where: {
            ($0.representedObject as? String) == representedValue
        }) {
            hostAudioInputPopup.select(item)
        }
        hostAudioInputPopup.isEnabled = snapshot.connectingPeerID == nil
            && host.allowsAudioPolicyChange
        hostAudioInputRefreshButton.isEnabled = snapshot.connectingPeerID == nil
            && host.allowsAudioPolicyChange
        if let selected = host.audioInputDeviceName {
            hostAudioInputStatusLabel.stringValue = host.audioInputDeviceAvailable
                ? "音频输入：\(selected)"
                : "已选设备不可用或名称不唯一；不会回退系统音频"
            hostAudioInputStatusLabel.textColor = host.audioInputDeviceAvailable
                ? .tertiaryLabelColor
                : .systemOrange
        } else {
            hostAudioInputStatusLabel.stringValue = "音频来源：系统音频（原生）"
            hostAudioInputStatusLabel.textColor = .tertiaryLabelColor
        }
    }

    @objc private func refreshHostAudioInputs() {
        guard snapshot.host.allowsAudioPolicyChange else { return }
        onRefreshHostAudioInputs?()
    }

    @objc private func chooseHostFileTransferReceiveRoot() {
        guard snapshot.host.allowsFileTransferPolicyChange else { return }
        onChooseHostFileTransferReceiveRoot?()
    }

    @objc private func revealHostPassword() { onRevealHostPassword?() }

    @objc private func copyHostID() {
        copyToPasteboard(snapshot.host.localID, label: "本机 ID")
    }

    @objc private func copyHostTemporaryPassword() {
        if let onCopyHostTemporaryPassword {
            onCopyHostTemporaryPassword()
            return
        }
        copyToPasteboard(snapshot.host.temporaryPassword, label: "临时密码")
    }

    func reportHostTemporaryPasswordCopy(_ succeeded: Bool) {
        showCopyFeedback(
            succeeded ? "已复制临时密码" : "复制失败，请重试",
            isError: !succeeded
        )
    }

    private func copyToPasteboard(_ value: String, label: String) {
        guard !value.isEmpty else {
            showCopyFeedback("\(label)暂不可用", isError: true)
            return
        }
        guard onWriteLocalClipboardText?(value) == true else {
            showCopyFeedback("复制失败，请重试", isError: true)
            return
        }
        showCopyFeedback("已复制\(label)", isError: false)
    }

    private func showCopyFeedback(_ text: String, isError: Bool) {
        copyFeedbackGeneration &+= 1
        let generation = copyFeedbackGeneration
        hostCopyFeedbackLabel.stringValue = text
        hostCopyFeedbackLabel.textColor = isError ? .systemOrange : HomePalette.accent
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            guard let self, self.copyFeedbackGeneration == generation else { return }
            self.hostCopyFeedbackLabel.stringValue = ""
        }
    }

    @objc private func regenerateHostPassword() { onRegenerateHostPassword?() }

    @objc private func setHostPermanentPassword() { onSetHostPermanentPassword?() }

    @objc private func clearHostPermanentPassword() { onClearHostPermanentPassword?() }

    @objc private func approveHostConnection() {
        guard let approval = snapshot.host.pendingApproval,
              approval.enabledActions.contains(.approve),
              !approval.isResolving else { return }
        onApproveHostConnection?(approval.connectionID)
    }

    @objc private func rejectHostConnection() {
        guard let approval = snapshot.host.pendingApproval,
              approval.enabledActions.contains(.reject),
              !approval.isResolving else { return }
        onRejectHostConnection?(approval.connectionID)
    }

    @objc private func disableHostSessionInput() {
        performHostSessionAction(.disableKeyboardAndMouse)
    }

    @objc private func disableHostSessionClipboardRead() {
        performHostSessionAction(.disableClipboardRead)
    }

    @objc private func disableHostSessionClipboardWrite() {
        performHostSessionAction(.disableClipboardWrite)
    }

    @objc private func disableHostSessionAudio() {
        performHostSessionAction(.disableSystemAudio)
    }

    @objc private func disconnectHostSession() {
        performHostSessionAction(.disconnect)
    }

    private func performHostSessionAction(_ action: HostSessionHomeAction) {
        guard let session = snapshot.host.activeSession,
              session.enabledActions.contains(action),
              session.pendingAction == nil else { return }
        switch action {
        case .disableKeyboardAndMouse:
            guard session.canDisableKeyboardAndMouse else { return }
        case .disableClipboardRead:
            guard session.canDisableClipboardRead else { return }
        case .disableClipboardWrite:
            guard session.canDisableClipboardWrite else { return }
        case .disableClipboard:
            guard session.canDisableClipboard else { return }
        case .disableSystemAudio:
            guard session.canDisableSystemAudio else { return }
        case .disconnect:
            break
        }
        onHostSessionAction?(session.connectionID, action)
    }

    @objc private func retryHostCommand() {
        guard let retry = snapshot.host.commandRetry else { return }
        onRetryHostCommand?(retry.connectionID)
    }

    @objc private func filterChanged() { renderDevices() }
}

// MARK: - 辅助视图

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class HomeSidebarButtonCell: NSButtonCell {
    private let horizontalPadding: CGFloat

    init(horizontalPadding: CGFloat) {
        self.horizontalPadding = horizontalPadding
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        horizontalPadding = 0
        super.init(coder: coder)
    }

    override func imageRect(forBounds rect: NSRect) -> NSRect {
        super.imageRect(forBounds: rect.insetBy(dx: horizontalPadding, dy: 0))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: horizontalPadding, dy: 0))
    }
}

private final class HomeSidebarButton: NSButton {
    let page: HomePage

    var isSelected = false {
        didSet { updateAppearance() }
    }

    init(page: HomePage) {
        self.page = page
        super.init(frame: .zero)
        cell = HomeSidebarButtonCell(horizontalPadding: 10)
        title = page.title
        image = NSImage(
            systemSymbolName: page.symbolName,
            accessibilityDescription: page.title
        )
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        font = .systemFont(ofSize: 12.5, weight: .medium)
        isBordered = false
        setButtonType(.momentaryPushIn)
        wantsLayer = true
        layer?.cornerRadius = 9
        contentTintColor = .secondaryLabelColor
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    private func updateAppearance() {
        layer?.backgroundColor = isSelected
            ? HomePalette.accent.withAlphaComponent(0.13).cgColor
            : NSColor.clear.cgColor
        contentTintColor = isSelected ? HomePalette.accent : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: page.title,
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: 12.5,
                    weight: isSelected ? .semibold : .medium
                ),
                .foregroundColor: isSelected
                    ? HomePalette.accent
                    : NSColor.secondaryLabelColor,
            ]
        )
    }
}

private final class HomePermissionRowView: NSView {
    let kind: HomeSystemPermissionKind
    var onOpenSettings: ((HomeSystemPermissionKind) -> Void)?

    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "正在检测")
    private let settingsButton = NSButton()

    init(kind: HomeSystemPermissionKind) {
        self.kind = kind
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ state: HomeSystemPermissionState) {
        statusLabel.stringValue = state.statusText
        let color: NSColor = state.isGranted ? .systemGreen : .systemOrange
        statusLabel.textColor = color
        statusDot.layer?.backgroundColor = color.cgColor
        settingsButton.title = state.isGranted ? "系统设置" : "去授权"
        settingsButton.contentTintColor = state.isGranted
            ? .secondaryLabelColor
            : HomePalette.accent
    }

    private func configure() {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: kind.symbolName,
            accessibilityDescription: kind.title
        ) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .medium
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])

        let title = NSTextField(labelWithString: kind.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let detail = NSTextField(labelWithString: kind.detail)
        detail.font = .systemFont(ofSize: 10.5)
        detail.textColor = .tertiaryLabelColor
        let copy = NSStackView(views: [title, detail])
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),
        ])
        statusLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        statusLabel.textColor = .systemOrange
        let status = NSStackView(views: [statusDot, statusLabel])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 6

        settingsButton.title = "去授权"
        settingsButton.bezelStyle = .inline
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        settingsButton.setAccessibilityLabel("打开\(kind.title)系统设置")

        let row = NSStackView(views: [
            icon,
            copy,
            NSView(),
            status,
            settingsButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 11
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
    }

    @objc private func openSettings() {
        onOpenSettings?(kind)
    }
}

/// FarPane 品牌标：两块屏幕通过青色光桥连接。
private final class BrandLogoView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let sx = bounds.width / 32
        let sy = bounds.height / 26
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: x * sx, y: y * sy)
        }

        let bridge = NSBezierPath()
        bridge.move(to: point(10.5, 9.2))
        bridge.line(to: point(21.5, 11.2))
        bridge.line(to: point(21.5, 16.0))
        bridge.line(to: point(10.5, 18.2))
        bridge.close()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.84, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.70, blue: 1.0, alpha: 1),
        ])?.draw(in: bridge, angle: 0)

        let left = panePath(
            outerTop: point(2.5, 4.0),
            innerTop: point(12.2, 8.4),
            innerBottom: point(12.2, 19.0),
            outerBottom: point(2.5, 23.0),
            roundsLeftEdge: true
        )
        NSGradient(colors: [
            NSColor(calibratedRed: 0.04, green: 0.57, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.98, alpha: 1),
        ])?.draw(in: left, angle: -35)

        let right = panePath(
            outerTop: point(29.5, 4.0),
            innerTop: point(19.8, 8.4),
            innerBottom: point(19.8, 19.0),
            outerBottom: point(29.5, 23.0),
            roundsLeftEdge: false
        )
        NSGradient(colors: [
            NSColor(calibratedRed: 0.61, green: 0.28, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.96, alpha: 1),
        ])?.draw(in: right, angle: 35)
    }

    private func panePath(
        outerTop: NSPoint,
        innerTop: NSPoint,
        innerBottom: NSPoint,
        outerBottom: NSPoint,
        roundsLeftEdge: Bool
    ) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: outerTop)
        path.line(to: innerTop)
        path.curve(
            to: innerBottom,
            controlPoint1: NSPoint(x: innerTop.x, y: innerTop.y + 1.2),
            controlPoint2: NSPoint(x: innerBottom.x, y: innerBottom.y - 1.2)
        )
        path.line(to: outerBottom)
        let edgeX = outerTop.x
        let direction: CGFloat = roundsLeftEdge ? -1 : 1
        path.curve(
            to: outerTop,
            controlPoint1: NSPoint(x: edgeX + direction * 0.8, y: outerBottom.y - 0.5),
            controlPoint2: NSPoint(x: edgeX + direction * 0.8, y: outerTop.y + 0.5)
        )
        path.close()
        return path
    }
}

/// accent 纯色填充按钮（hover / 按下 / 禁用状态）
private final class AccentButton: NSButton {
    private var isHovering = false
    private var isPressing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 13.5, weight: .semibold)
        applyTitleStyle()
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet {
            applyTitleStyle()
            updateBackground()
        }
    }

    override var title: String {
        didSet { applyTitleStyle() }
    }

    private func applyTitleStyle() {
        let color: NSColor = isEnabled
            ? HomePalette.inkOnAccent
            : .secondaryLabelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
        ])
    }

    private func updateBackground() {
        guard let layer else { return }
        let accent = HomePalette.accent
        if !isEnabled {
            layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.4).cgColor
        } else if isPressing {
            layer.backgroundColor = (accent.blended(withFraction: 0.18, of: .black) ?? accent).cgColor
        } else if isHovering {
            layer.backgroundColor = (accent.blended(withFraction: 0.1, of: .white) ?? accent).cgColor
        } else {
            layer.backgroundColor = accent.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        updateBackground()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isPressing = false
        updateBackground()
        super.mouseUp(with: event)
    }
}

// MARK: - 设备行

private final class DeviceRowView: NSView {
    var onAction: ((HomeDeviceAction) -> Void)?

    private let item: HomeDeviceItem
    private let favoriteButton = NSButton()

    init(item: HomeDeviceItem, isConnecting: Bool) {
        self.item = item
        super.init(frame: .zero)
        configure(isConnecting: isConnecting)
    }

    required init?(coder: NSCoder) { nil }

    private func configure(isConnecting: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = HomePalette.panel.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor

        favoriteButton.bezelStyle = .inline
        favoriteButton.image = NSImage(
            systemSymbolName: item.device.isFavorite ? "star.fill" : "star",
            accessibilityDescription: item.device.isFavorite ? "取消收藏" : "收藏"
        )
        favoriteButton.contentTintColor = item.device.isFavorite ? .systemYellow : .tertiaryLabelColor
        favoriteButton.target = self
        favoriteButton.action = #selector(toggleFavorite)

        // 设备类型图标
        let avatarView = NSView()
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 6
        avatarView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
        let avatarIcon = NSImageView(image: NSImage(
            systemSymbolName: "desktopcomputer",
            accessibilityDescription: "电脑"
        ) ?? NSImage())
        avatarIcon.contentTintColor = .secondaryLabelColor
        avatarView.addSubview(avatarIcon)
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 30),
            avatarView.heightAnchor.constraint(equalToConstant: 30),
            avatarIcon.widthAnchor.constraint(equalToConstant: 15),
            avatarIcon.heightAnchor.constraint(equalToConstant: 15),
            avatarIcon.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarIcon.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
        ])

        let name = NSTextField(labelWithString: item.device.resolvedDisplayName)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        // meta：ID（等宽数字）· 相对时间 · 已验证徽标
        let idLabel = NSTextField(labelWithString: formatPeerID(item.device.peerID))
        idLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        idLabel.textColor = .secondaryLabelColor
        idLabel.lineBreakMode = .byTruncatingTail

        var metaParts: [NSView] = [idLabel]
        if let date = item.device.lastSuccessfulConnectionAt {
            let timeLabel = NSTextField(labelWithString: relativeTime(date))
            timeLabel.font = .systemFont(ofSize: 12)
            timeLabel.textColor = .secondaryLabelColor
            let dotLabel = NSTextField(labelWithString: "·")
            dotLabel.font = .systemFont(ofSize: 12)
            dotLabel.textColor = .tertiaryLabelColor
            let badgeView = verifiedBadge()
            metaParts.append(contentsOf: [dotLabel, timeLabel, badgeView])
        }
        let detail = NSStackView(views: metaParts)
        detail.orientation = .horizontal
        detail.alignment = .centerY
        detail.spacing = 7
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let identity = NSStackView(views: [name, detail])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 3
        identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let credential = NSImageView(image: NSImage(
            systemSymbolName: item.hasSavedPassword ? "lock.fill" : "lock.open",
            accessibilityDescription: item.hasSavedPassword ? "已保存密码" : "未保存密码"
        ) ?? NSImage())
        credential.contentTintColor = item.hasSavedPassword ? .secondaryLabelColor : .tertiaryLabelColor
        credential.toolTip = item.hasSavedPassword ? "密码已保存在此 Mac 的钥匙串" : "连接时需要输入密码"

        let sendFiles = NSButton(
            title: "发文件",
            target: self,
            action: #selector(sendFiles)
        )
        sendFiles.bezelStyle = .rounded
        sendFiles.toolTip = "连接后立即选择文件或文件夹发送到远端"
        sendFiles.setAccessibilityLabel("发送文件到此设备")
        sendFiles.isEnabled = !isConnecting

        let connect = NSButton(title: isConnecting ? "连接中…" : "连接", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded
        connect.contentTintColor = isConnecting ? .tertiaryLabelColor : HomePalette.accent
        connect.font = .systemFont(ofSize: 12, weight: .semibold)
        connect.isEnabled = !isConnecting

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作") ?? NSImage(),
            target: self,
            action: #selector(showMenu)
        )
        more.bezelStyle = .inline
        more.toolTip = "更多操作"

        let row = NSStackView(views: [
            avatarView,
            favoriteButton,
            identity,
            NSView(),
            credential,
            sendFiles,
            connect,
            more,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            connect.widthAnchor.constraint(equalToConstant: 64),
            sendFiles.widthAnchor.constraint(equalToConstant: 68),
            credential.widthAnchor.constraint(equalToConstant: 18),
        ])
    }

    private func verifiedBadge() -> NSView {
        let badgeView = NSView()
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 8
        badgeView.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
        let label = NSTextField(labelWithString: "已验证")
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .systemGreen
        badgeView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
            badgeView.heightAnchor.constraint(equalToConstant: 17),
        ])
        return badgeView
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = HomePalette.panelHover.cgColor
        layer?.borderColor = HomePalette.accent.withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = HomePalette.panel.cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
    }

    private func formatPeerID(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.allSatisfy(\.isNumber) else { return value }
        return stride(from: 0, to: compact.count, by: 3).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(3, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: " ")
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc private func connect() { onAction?(.connect) }

    @objc private func sendFiles() { onAction?(.sendFiles) }

    @objc private func toggleFavorite() { onAction?(.toggleFavorite) }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        addItem(item.device.isFavorite ? "取消收藏" : "收藏", #selector(menuFavorite), to: menu)
        addItem("重命名…", #selector(menuRename), to: menu)
        menu.addItem(.separator())
        addItem("更新密码并连接…", #selector(menuUpdatePassword), to: menu)
        let deletePassword = addItem("删除已保存密码", #selector(menuDeletePassword), to: menu)
        deletePassword.isEnabled = item.hasSavedPassword
        menu.addItem(.separator())
        let deleteDevice = addItem("删除设备…", #selector(menuDeleteDevice), to: menu)
        deleteDevice.isEnabled = true
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: sender.bounds.minY), in: sender)
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    @objc private func menuFavorite() { onAction?(.toggleFavorite) }
    @objc private func menuRename() { onAction?(.rename) }
    @objc private func menuUpdatePassword() { onAction?(.updatePassword) }
    @objc private func menuDeletePassword() { onAction?(.deletePassword) }
    @objc private func menuDeleteDevice() { onAction?(.deleteDevice) }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
