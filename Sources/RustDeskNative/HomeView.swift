import AppKit
import ConnectionCatalog

struct HomeDeviceItem: Equatable {
    let device: SavedDevice
    let hasSavedPassword: Bool
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
    var allowsClipboardPolicyChange: Bool
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
    var host: HostHomeSnapshot
}

enum HomeDeviceAction {
    case connect
    case toggleFavorite
    case rename
    case updatePassword
    case deletePassword
    case deleteDevice
}

final class HomeView: NSView, NSTextFieldDelegate, NSSearchFieldDelegate {
    var onQuickConnect: ((String) -> Void)?
    var onOpenServerSettings: (() -> Void)?
    var onDeviceAction: ((UUID, HomeDeviceAction) -> Void)?
    var onHostToggle: ((Bool) -> Void)?
    var onHostClipboardReadToggle: ((Bool) -> Void)?
    var onHostClipboardWriteToggle: ((Bool) -> Void)?
    var onHostClipboardRichTextReadToggle: ((Bool) -> Void)?
    var onHostClipboardRichTextWriteToggle: ((Bool) -> Void)?
    var onRevealHostPassword: (() -> Void)?
    var onRegenerateHostPassword: (() -> Void)?
    var onSetHostPermanentPassword: (() -> Void)?
    var onClearHostPermanentPassword: (() -> Void)?
    var onApproveHostConnection: ((String) -> Void)?
    var onRejectHostConnection: ((String) -> Void)?
    var onHostSessionAction: ((String, HostSessionHomeAction) -> Void)?
    var onRetryHostCommand: ((String) -> Void)?

    private let serverButton = NSButton()
    private let serverStatusDot = NSView()
    private let peerField = NSTextField()
    private let peerContainer = NSView()
    private let connectButton = AccentButton(title: "连接", target: nil, action: nil)
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
    private let hostRevealButton = NSButton()
    private let hostRegenerateButton = NSButton()
    private let hostPermanentPasswordLabel = NSTextField(labelWithString: "永久密码：未设置")
    private let hostSetPermanentPasswordButton = NSButton()
    private let hostClearPermanentPasswordButton = NSButton()
    private let hostClipboardReadSwitch = NSSwitch()
    private let hostClipboardWriteSwitch = NSSwitch()
    private let hostClipboardRichTextReadSwitch = NSSwitch()
    private let hostClipboardRichTextWriteSwitch = NSSwitch()
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
    private var snapshot = HomeSnapshot(
        server: nil,
        devices: [],
        statusText: "就绪",
        errorText: "",
        connectingPeerID: nil,
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
        peerField.isEnabled = snapshot.connectingPeerID == nil
        connectButton.title = snapshot.connectingPeerID == nil ? "连接" : "连接中…"
        serverButton.isEnabled = snapshot.connectingPeerID == nil
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
        let clipboardPolicyInteractive = snapshot.connectingPeerID == nil
            && snapshot.host.allowsClipboardPolicyChange
        hostClipboardReadSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardWriteSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardRichTextReadSwitch.isEnabled = clipboardPolicyInteractive
        hostClipboardRichTextWriteSwitch.isEnabled = clipboardPolicyInteractive
        hostStatusLabel.stringValue = snapshot.host.statusText
        hostStatusDot.layer?.backgroundColor = hostStatusColor(snapshot.host).cgColor
        hostIDLabel.stringValue = "本机 ID：\(snapshot.host.localID.nonEmpty ?? "—")"
        hostPasswordLabel.stringValue = "临时密码：\(snapshot.host.temporaryPassword.nonEmpty ?? "未显示")"
        hostRevealButton.title = snapshot.host.temporaryPassword.isEmpty ? "显示" : "隐藏"
        hostRevealButton.isEnabled = snapshot.host.allowsHostCommands
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
        countBadge.stringValue = "\(snapshot.devices.count)"
        renderDevices()
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
                ? "永久密码：由管理员管理"
                : "永久密码：不允许更改"
        }
        if host.localPermanentPasswordSet {
            return "永久密码：已设置"
        }
        if host.usingPresetPassword || host.effectivePermanentPasswordSet {
            return "永久密码：预设密码生效"
        }
        return "永久密码：未设置"
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
        window?.makeFirstResponder(peerField)
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        // ---------- Header ----------
        let brand = NSStackView(views: [BrandLogoView(), brandNameLabel()])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 9

        let title = NSTextField(labelWithString: "控制远程设备")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: "从最近设备快速连接，或输入新的 RustDesk 设备 ID。"
        )
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)

        let headerText = NSStackView(views: [brand, title, subtitle])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 5

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

        let serverWrap = NSStackView(views: [serverStatusDot, serverButton])
        serverWrap.orientation = .horizontal
        serverWrap.alignment = .centerY
        serverWrap.spacing = 6

        let header = NSStackView(views: [headerText, NSView(), serverWrap])
        header.orientation = .horizontal
        header.alignment = .top

        // ---------- 快速连接卡片 ----------
        peerField.placeholderString = "输入对方设备 ID，例如 123 456 789"
        peerField.font = .systemFont(ofSize: 14.5)
        peerField.isBordered = false
        peerField.drawsBackground = false
        peerField.focusRingType = .none
        peerField.delegate = self
        peerField.target = self
        peerField.action = #selector(connectQuickly)
        peerField.setAccessibilityLabel("远端设备 ID")
        peerField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let peerIcon = NSImageView(image: NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "设备"
        ) ?? NSImage())
        peerIcon.contentTintColor = .tertiaryLabelColor
        peerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            peerIcon.widthAnchor.constraint(equalToConstant: 15),
            peerIcon.heightAnchor.constraint(equalToConstant: 15),
        ])

        let hintView = NSView()
        hintView.wantsLayer = true
        hintView.layer?.cornerRadius = 9
        hintView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.16).cgColor
        let hintLabel = NSTextField(labelWithString: "回车连接")
        hintLabel.font = .systemFont(ofSize: 11, weight: .medium)
        hintLabel.textColor = .tertiaryLabelColor
        hintView.addSubview(hintLabel)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: hintView.leadingAnchor, constant: 9),
            hintLabel.trailingAnchor.constraint(equalTo: hintView.trailingAnchor, constant: -9),
            hintLabel.centerYAnchor.constraint(equalTo: hintView.centerYAnchor),
            hintView.heightAnchor.constraint(equalToConstant: 20),
        ])

        let fieldRow = NSStackView(views: [peerIcon, peerField, hintView])
        fieldRow.orientation = .horizontal
        fieldRow.alignment = .centerY
        fieldRow.spacing = 8
        fieldRow.translatesAutoresizingMaskIntoConstraints = false

        peerContainer.wantsLayer = true
        peerContainer.layer?.cornerRadius = 8
        peerContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        peerContainer.layer?.borderColor = NSColor.separatorColor.cgColor
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

        let quickRow = NSStackView(views: [peerContainer, connectButton])
        quickRow.orientation = .horizontal
        quickRow.alignment = .centerY
        quickRow.spacing = 12
        quickRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            peerContainer.heightAnchor.constraint(equalToConstant: 34),
            connectButton.widthAnchor.constraint(equalToConstant: 82),
            connectButton.heightAnchor.constraint(equalToConstant: 34),
        ])

        let quickLabel = NSTextField(labelWithString: "快速连接")
        quickLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        quickLabel.textColor = .tertiaryLabelColor

        let quickCard = NSStackView(views: [quickLabel, quickRow])
        quickCard.orientation = .vertical
        quickCard.alignment = .leading
        quickCard.spacing = 8

        let quickContainer = NSView()
        quickContainer.wantsLayer = true
        quickContainer.layer?.cornerRadius = 12
        quickContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        quickContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        quickContainer.layer?.borderWidth = 1
        quickContainer.layer?.shadowColor = NSColor.black.cgColor
        quickContainer.layer?.shadowOpacity = 0.06
        quickContainer.layer?.shadowRadius = 3
        quickContainer.layer?.shadowOffset = CGSize(width: 0, height: 1)
        quickContainer.addSubview(quickCard)
        quickCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            quickCard.leadingAnchor.constraint(equalTo: quickContainer.leadingAnchor, constant: 16),
            quickCard.trailingAnchor.constraint(equalTo: quickContainer.trailingAnchor, constant: -16),
            quickCard.topAnchor.constraint(equalTo: quickContainer.topAnchor, constant: 14),
            quickCard.bottomAnchor.constraint(equalTo: quickContainer.bottomAnchor, constant: -14),
        ])

        // ---------- 本机 Host ----------
        let hostTitle = NSTextField(labelWithString: "允许连接此 Mac")
        hostTitle.font = .systemFont(ofSize: 14, weight: .semibold)

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

        let hostHeader = NSStackView(views: [
            hostTitle,
            hostStatusDot,
            hostStatusLabel,
            NSView(),
            hostSwitch,
        ])
        hostHeader.orientation = .horizontal
        hostHeader.alignment = .centerY
        hostHeader.spacing = 7

        hostIDLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        hostIDLabel.textColor = .secondaryLabelColor
        hostIDLabel.lineBreakMode = .byTruncatingMiddle
        hostPasswordLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        hostPasswordLabel.textColor = .secondaryLabelColor

        hostRevealButton.title = "显示"
        hostRevealButton.bezelStyle = .inline
        hostRevealButton.target = self
        hostRevealButton.action = #selector(revealHostPassword)
        hostRegenerateButton.title = "换一个"
        hostRegenerateButton.bezelStyle = .inline
        hostRegenerateButton.target = self
        hostRegenerateButton.action = #selector(regenerateHostPassword)

        let hostDetails = NSStackView(views: [
            hostIDLabel,
            hostPasswordLabel,
            NSView(),
            hostRevealButton,
            hostRegenerateButton,
        ])
        hostDetails.orientation = .horizontal
        hostDetails.alignment = .centerY
        hostDetails.spacing = 12
        hostIDLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostPasswordLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

        let hostClipboardSettings = NSStackView(views: [
            hostClipboardTitle,
            hostClipboardSmallTextTitle,
            hostClipboardReadRow,
            hostClipboardWriteRow,
            hostClipboardRichTextTitle,
            hostClipboardRichTextReadRow,
            hostClipboardRichTextWriteRow,
        ])
        hostClipboardSettings.orientation = .vertical
        hostClipboardSettings.alignment = .leading
        hostClipboardSettings.spacing = 5
        for view in [
            hostClipboardTitle,
            hostClipboardReadRow,
            hostClipboardWriteRow,
        ] {
            view.widthAnchor.constraint(
                equalTo: hostClipboardSettings.widthAnchor
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

        let hostCard = NSStackView(views: [
            hostHeader,
            hostDetails,
            hostPermanentPasswordDetails,
            hostClipboardSettings,
            hostSessionContainer,
            hostApprovalContainer,
            hostMediaDiagnosticLabel,
            hostErrorLabel,
            hostCommandRetryButton,
        ])
        hostCard.orientation = .vertical
        hostCard.alignment = .leading
        hostCard.spacing = 7
        for view in [
            hostHeader,
            hostDetails,
            hostPermanentPasswordDetails,
            hostClipboardSettings,
            hostSessionContainer,
            hostApprovalContainer,
            hostMediaDiagnosticLabel,
            hostErrorLabel,
            hostCommandRetryButton,
        ] {
            view.widthAnchor.constraint(equalTo: hostCard.widthAnchor).isActive = true
        }

        let hostContainer = NSView()
        hostContainer.wantsLayer = true
        hostContainer.layer?.cornerRadius = 12
        hostContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        hostContainer.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        hostContainer.layer?.borderWidth = 1
        hostContainer.addSubview(hostCard)
        hostCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostCard.leadingAnchor.constraint(equalTo: hostContainer.leadingAnchor, constant: 16),
            hostCard.trailingAnchor.constraint(equalTo: hostContainer.trailingAnchor, constant: -16),
            hostCard.topAnchor.constraint(equalTo: hostContainer.topAnchor, constant: 11),
            hostCard.bottomAnchor.constraint(equalTo: hostContainer.bottomAnchor, constant: -11),
        ])

        // ---------- 列表工具栏 ----------
        let recentTitle = NSTextField(labelWithString: "最近连接")
        recentTitle.font = .systemFont(ofSize: 17, weight: .semibold)

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
        listStack.spacing = 0
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

        // ---------- 底部状态栏 ----------
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
        let versionBadge = NSView()
        versionBadge.wantsLayer = true
        versionBadge.layer?.cornerRadius = 9
        versionBadge.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.16).cgColor
        let versionLabel = NSTextField(labelWithString: versionText)
        versionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        versionLabel.textColor = .secondaryLabelColor
        versionBadge.addSubview(versionLabel)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            versionLabel.leadingAnchor.constraint(equalTo: versionBadge.leadingAnchor, constant: 9),
            versionLabel.trailingAnchor.constraint(equalTo: versionBadge.trailingAnchor, constant: -9),
            versionLabel.centerYAnchor.constraint(equalTo: versionBadge.centerYAnchor),
            versionBadge.heightAnchor.constraint(equalToConstant: 18),
        ])

        let footer = NSStackView(views: [statusDot, statusLabel, NSView(), versionBadge])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7

        // ---------- 内容组装 ----------
        let content = NSStackView(views: [
            header,
            quickContainer,
            hostContainer,
            listToolbar,
            errorLabel,
            scrollView,
            footer,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.setCustomSpacing(24, after: header)
        content.setCustomSpacing(12, after: quickContainer)
        content.setCustomSpacing(20, after: hostContainer)
        content.setCustomSpacing(8, after: listToolbar)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        for view in [header, quickContainer, hostContainer, listToolbar, errorLabel, scrollView, footer] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let deviceListMinimumHeight = scrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 80
        )
        deviceListMinimumHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 38),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -38),
            content.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -18),
            deviceListMinimumHeight,
        ])
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
        layer.borderColor = (focused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer.shadowColor = NSColor.controlAccentColor.cgColor
        layer.shadowOpacity = focused ? 0.22 : 0
        layer.shadowRadius = 4
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

        for (index, item) in items.enumerated() {
            let row = DeviceRowView(
                item: item,
                isConnecting: snapshot.connectingPeerID == item.device.peerID
            )
            row.onAction = { [weak self] action in
                self?.onDeviceAction?(item.device.id, action)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            if index < items.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                listStack.addArrangedSubview(separator)
                separator.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
    }

    @objc private func connectQuickly() {
        let peerID = peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peerID.isEmpty,
              snapshot.server?.isComplete == true,
              snapshot.connectingPeerID == nil else { return }
        onQuickConnect?(peerID)
    }

    @objc private func openServerSettings() { onOpenServerSettings?() }

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

    @objc private func revealHostPassword() { onRevealHostPassword?() }

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

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
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
        let color: NSColor = isEnabled ? .white : .white.withAlphaComponent(0.55)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
        ])
    }

    private func updateBackground() {
        guard let layer else { return }
        let accent = NSColor.controlAccentColor
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
        layer?.cornerRadius = 10

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
        avatarView.layer?.cornerRadius = 8
        avatarView.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
        let avatarIcon = NSImageView(image: NSImage(
            systemSymbolName: "desktopcomputer",
            accessibilityDescription: "电脑"
        ) ?? NSImage())
        avatarIcon.contentTintColor = .secondaryLabelColor
        avatarView.addSubview(avatarIcon)
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 34),
            avatarView.heightAnchor.constraint(equalToConstant: 34),
            avatarIcon.widthAnchor.constraint(equalToConstant: 17),
            avatarIcon.heightAnchor.constraint(equalToConstant: 17),
            avatarIcon.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarIcon.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
        ])

        let name = NSTextField(labelWithString: item.device.resolvedDisplayName)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        // meta：ID（等宽数字）· 相对时间 · 已验证徽标
        let idLabel = NSTextField(labelWithString: formatPeerID(item.device.peerID))
        idLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
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

        let connect = NSButton(title: isConnecting ? "连接中…" : "连接", target: self, action: #selector(connect))
        connect.bezelStyle = .rounded
        connect.contentTintColor = isConnecting ? .tertiaryLabelColor : .controlAccentColor
        connect.font = .systemFont(ofSize: 13, weight: .semibold)
        connect.isEnabled = !isConnecting

        let more = NSButton(
            image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多操作") ?? NSImage(),
            target: self,
            action: #selector(showMenu)
        )
        more.bezelStyle = .inline
        more.toolTip = "更多操作"

        let row = NSStackView(views: [avatarView, favoriteButton, identity, NSView(), credential, connect, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            connect.widthAnchor.constraint(equalToConstant: 76),
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
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
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
