import AppKit
import VideoPipeline
import ViewerInput

struct InteractiveConnectionDraft {
    let rendezvousServer: String
    let serverPublicKey: String
    let peerID: String
    let password: String
    let forceRelay: Bool
    let rememberProfile: Bool

    var profile: ViewerConnectionProfile {
        ViewerConnectionProfile(
            rendezvousServer: rendezvousServer,
            serverPublicKey: serverPublicKey,
            peerID: peerID,
            forceRelay: forceRelay
        )
    }
}

final class ConnectionView: NSView {
    var onConnect: ((InteractiveConnectionDraft) -> Void)?
    var onClearSavedProfile: (() -> Void)?

    private let serverField = NSTextField()
    private let keyField = NSTextField()
    private let peerField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let relayButton = NSButton(
        checkboxWithTitle: "始终通过中继连接（受限网络或排障时使用）",
        target: nil,
        action: nil
    )
    private let rememberButton = NSButton(
        checkboxWithTitle: "记住服务器与设备 ID",
        target: nil,
        action: nil
    )
    private let clearButton = NSButton(title: "清除已保存配置", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)

    init(savedProfile: ViewerConnectionProfile?) {
        super.init(frame: .zero)
        if let savedProfile {
            serverField.stringValue = savedProfile.rendezvousServer
            keyField.stringValue = savedProfile.serverPublicKey
            peerField.stringValue = savedProfile.peerID
            relayButton.state = savedProfile.forceRelay ? .on : .off
        }
        rememberButton.state = .on
        clearButton.isHidden = savedProfile == nil
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
        connectButton.isEnabled = true
    }

    private func configure() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let product = NSTextField(labelWithString: "RustDesk Native Viewer")
        product.font = .systemFont(ofSize: 13, weight: .semibold)
        product.textColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "连接远程设备")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(
            wrappingLabelWithString: "连接、认证、加密与输入协议由内置 RustDesk Core 处理。"
        )
        subtitle.textColor = .secondaryLabelColor
        let security = NSTextField(
            wrappingLabelWithString: "密码仅用于本次连接，始终不会保存；服务器配置仅在勾选后保存在本机。"
        )
        security.textColor = .secondaryLabelColor

        peerField.placeholderString = "远端 RustDesk 设备 ID"
        passwordField.placeholderString = "本次连接使用的密码"
        serverField.placeholderString = "例如 rustdesk.example.com:21116"
        keyField.placeholderString = "自建服务器公钥"

        let deviceForm = configuredGrid([
            [NSTextField(labelWithString: "设备 ID"), peerField],
            [NSTextField(labelWithString: "访问密码"), passwordField],
        ])
        let serverForm = configuredGrid([
            [NSTextField(labelWithString: "ID 服务器"), serverField],
            [NSTextField(labelWithString: "服务器公钥"), keyField],
        ])
        let serverHelp = NSTextField(
            wrappingLabelWithString: "通常只需填写 hbbs 地址与公钥；中继地址由 RustDesk Core 自动发现。"
        )
        serverHelp.textColor = .tertiaryLabelColor
        serverHelp.font = .systemFont(ofSize: 12)

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        clearButton.bezelStyle = .inline
        clearButton.target = self
        clearButton.action = #selector(clearSavedProfile)

        let persistence = NSStackView(views: [rememberButton, clearButton])
        persistence.orientation = .horizontal
        persistence.alignment = .centerY
        persistence.spacing = 12

        let actions = NSStackView(views: [relayButton, NSView(), connectButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY

        let stack = NSStackView(views: [
            product,
            title,
            subtitle,
            sectionTitle("远程设备"),
            deviceForm,
            sectionTitle("服务器"),
            serverForm,
            serverHelp,
            persistence,
            security,
            errorLabel,
            actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(4, after: product)
        stack.setCustomSpacing(6, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            security.widthAnchor.constraint(equalTo: stack.widthAnchor),
            serverHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func sectionTitle(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func configuredGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 430
        rows.flatMap { $0 }.forEach { view in
            (view as? NSTextField)?.font = .systemFont(ofSize: 14)
        }
        return grid
    }

    @objc private func connect() {
        let draft = InteractiveConnectionDraft(
            rendezvousServer: serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            serverPublicKey: keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            peerID: peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: passwordField.stringValue,
            forceRelay: relayButton.state == .on,
            rememberProfile: rememberButton.state == .on
        )
        guard !draft.rendezvousServer.isEmpty,
              !draft.serverPublicKey.isEmpty,
              !draft.peerID.isEmpty else {
            showError("请填写设备 ID、RustDesk ID 服务器和服务器公钥。")
            return
        }
        connectButton.isEnabled = false
        errorLabel.isHidden = true
        onConnect?(draft)
        passwordField.stringValue = ""
    }

    @objc private func clearSavedProfile() {
        serverField.stringValue = ""
        keyField.stringValue = ""
        peerField.stringValue = ""
        passwordField.stringValue = ""
        relayButton.state = .off
        clearButton.isHidden = true
        onClearSavedProfile?()
    }
}

final class ViewerChromeView: NSView {
    let videoView: ViewerMetalView
    var onDisconnect: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onToggleKeyboardGrab: (() -> Void)?
    var onOpenKeyboardPermissions: (() -> Void)?

    private let hudPanel = NSVisualEffectView()
    private let hudLabel = NSTextField(labelWithString: "正在等待视频…")
    private let stateLabel = NSTextField(labelWithString: "正在连接…")
    private let keyboardStatusLabel = NSTextField(labelWithString: "")
    private let keyboardGrabButton = NSButton(title: "独占键盘", target: nil, action: nil)
    private let keyboardPermissionButton = NSButton(title: "权限设置", target: nil, action: nil)
    private let showsAcceptanceControls: Bool
    private var hudVisible = true
    private var keyboardGrabActive = false
    private var keyboardGrabAvailable = false
    private weak var metrics: PipelineMetrics?

    init(
        videoView: ViewerMetalView,
        metrics: PipelineMetrics,
        showsAcceptanceControls: Bool
    ) {
        self.videoView = videoView
        self.metrics = metrics
        self.showsAcceptanceControls = showsAcceptanceControls
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    func updateState(_ text: String, isError: Bool = false) {
        stateLabel.stringValue = text
        stateLabel.textColor = isError ? .systemRed : .labelColor
    }

    func setKeyboardGrabAvailable(_ available: Bool) {
        keyboardGrabAvailable = available
        keyboardGrabButton.isEnabled = available || keyboardGrabActive
    }

    func updateKeyboardGrab(active: Bool, message: String?, isError: Bool) {
        keyboardGrabActive = active
        keyboardGrabButton.title = active ? "退出独占" : "独占键盘"
        keyboardGrabButton.isEnabled = active || keyboardGrabAvailable
        keyboardStatusLabel.stringValue = message ?? ""
        keyboardStatusLabel.textColor = isError ? .systemRed : .systemOrange
        keyboardStatusLabel.isHidden = message?.isEmpty != false
        keyboardPermissionButton.isHidden = !isError
    }

    func updateHUD(_ value: PipelineHUDSnapshot) {
        hudLabel.stringValue = String(
            format: "远端 %dx%d  →  本地 %dx%d\n编码 %.1f FPS  呈现 %.1f FPS  延迟 %d ms\n解码 %.2f ms  呈现 %.2f ms  丢帧 %d\n队列 %d/%d  CPU %.1f%%  内存 %.1f MB\n输入 %d  拒绝 %d",
            value.remoteWidth, value.remoteHeight, value.drawableWidth, value.drawableHeight,
            value.encodedFPS, value.presentedFPS, value.networkDelayMS,
            value.decodeMS, value.renderMS, value.droppedFrames,
            value.decoderQueueDepth, value.rendererQueueDepth, value.cpuPercent, value.residentMB,
            value.inputEvents, value.inputRejectedEvents
        )
    }

    private func configure() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        hudPanel.material = .hudWindow
        hudPanel.blendingMode = .withinWindow
        hudPanel.state = .active
        hudPanel.wantsLayer = true
        hudPanel.layer?.cornerRadius = 10
        hudLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hudLabel.textColor = .white
        hudLabel.maximumNumberOfLines = 0
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudPanel.addSubview(hudLabel)
        NSLayoutConstraint.activate([
            hudLabel.leadingAnchor.constraint(equalTo: hudPanel.leadingAnchor, constant: 12),
            hudLabel.trailingAnchor.constraint(equalTo: hudPanel.trailingAnchor, constant: -12),
            hudLabel.topAnchor.constraint(equalTo: hudPanel.topAnchor, constant: 10),
            hudLabel.bottomAnchor.constraint(equalTo: hudPanel.bottomAnchor, constant: -10),
        ])

        let fullscreen = actionButton("全屏", #selector(toggleFullscreen))
        let hud = actionButton("HUD", #selector(toggleHUD))
        let acceptance = actionButton("验收记录", #selector(showChecklist))
        let disconnect = actionButton("断开", #selector(disconnect))
        keyboardStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        keyboardStatusLabel.isHidden = true
        keyboardStatusLabel.lineBreakMode = .byTruncatingTail
        keyboardGrabButton.bezelStyle = .rounded
        keyboardGrabButton.target = self
        keyboardGrabButton.action = #selector(toggleKeyboardGrab)
        keyboardGrabButton.isEnabled = false
        keyboardGrabButton.toolTip = "捕获本机系统快捷键并发送到远端；按 ⌃⌥⇧Esc 退出"
        keyboardPermissionButton.bezelStyle = .inline
        keyboardPermissionButton.target = self
        keyboardPermissionButton.action = #selector(openKeyboardPermissions)
        keyboardPermissionButton.isHidden = true
        var toolbarViews: [NSView] = [
            stateLabel, NSView(), keyboardStatusLabel, keyboardPermissionButton,
            keyboardGrabButton,
        ]
        if showsAcceptanceControls { toolbarViews.append(acceptance) }
        toolbarViews.append(contentsOf: [hud, fullscreen, disconnect])
        let toolbar = NSStackView(views: toolbarViews)
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.88).cgColor
        toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        hudPanel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hudPanel)
        addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            hudPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hudPanel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
        ])
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func toggleFullscreen() {
        metrics?.recordFullscreenToggle()
        onToggleFullscreen?()
    }

    @objc private func toggleHUD() {
        hudVisible.toggle()
        hudPanel.isHidden = !hudVisible
        metrics?.recordHUDToggle()
    }

    @objc private func toggleKeyboardGrab() { onToggleKeyboardGrab?() }

    @objc private func openKeyboardPermissions() { onOpenKeyboardPermissions?() }

    @objc private func disconnect() { onDisconnect?() }

    @objc private func showChecklist() {
        guard let metrics else { return }
        let checks = [
            ("click", "点击已在远端产生可见反馈"),
            ("drag", "拖拽已在远端产生可见反馈"),
            ("scroll", "滚轮已在远端产生可见反馈"),
            ("text", "英文与本地中文输入法提交均正确"),
            ("key-repeat", "长按退格等按键重复正常且无卡键"),
            ("shortcut", "常用修饰键快捷键正确"),
            ("exclusive-keyboard", "独占模式下系统快捷键仅在远端触发，退出组合键正常"),
            ("fullscreen", "全屏进入与退出正常"),
            ("hud", "HUD 显示与切换正常"),
            ("error-state", "脱敏错误状态显示正常"),
        ]
        let current = metrics.functionalChecksSnapshot()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        var buttons: [(String, NSButton)] = []
        for (key, title) in checks {
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = current[key] == true ? .on : .off
            stack.addArrangedSubview(button)
            buttons.append((key, button))
        }
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 272)
        let alert = NSAlert()
        alert.messageText = "人工功能反馈"
        alert.informativeText = "只勾选已在真实远端画面中亲自确认成功的项目。"
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for (key, button) in buttons {
            metrics.recordFunctionalCheck(key, passed: button.state == .on)
        }
    }
}
