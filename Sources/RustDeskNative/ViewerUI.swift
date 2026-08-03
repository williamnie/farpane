import AppKit
import VideoPipeline

struct InteractiveConnectionDraft {
    let coreLibrary: String
    let rendezvousServer: String
    let serverPublicKey: String
    let peerID: String
    let password: String
    let forceRelay: Bool
}

final class ConnectionView: NSView {
    var onConnect: ((InteractiveConnectionDraft) -> Void)?

    private let coreField = NSTextField()
    private let serverField = NSTextField()
    private let keyField = NSTextField()
    private let peerField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let relayButton = NSButton(checkboxWithTitle: "强制使用 Hermes 中继", target: nil, action: nil)
    private let errorLabel = NSTextField(labelWithString: "")
    private let connectButton = NSButton(title: "连接", target: nil, action: nil)

    init(defaultCorePath: String) {
        super.init(frame: .zero)
        coreField.stringValue = defaultCorePath
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

        let title = NSTextField(labelWithString: "RustDesk Native Viewer")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "连接、认证和输入协议均由固定版本 RustDesk Core 处理")
        subtitle.textColor = .secondaryLabelColor
        let security = NSTextField(wrappingLabelWithString: "密码仅用于本次连接，不会持久化，也不会写入日志或证据。")
        security.textColor = .secondaryLabelColor

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Core 动态库"), coreField],
            [NSTextField(labelWithString: "Hermes 服务"), serverField],
            [NSTextField(labelWithString: "服务公钥"), keyField],
            [NSTextField(labelWithString: "远端 ID"), peerField],
            [NSTextField(labelWithString: "密码"), passwordField],
        ])
        form.rowSpacing = 12
        form.columnSpacing = 14
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 430
        [coreField, serverField, keyField, peerField, passwordField].forEach {
            $0.font = .systemFont(ofSize: 14)
        }

        relayButton.state = .on
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let actions = NSStackView(views: [relayButton, NSView(), connectButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY

        let stack = NSStackView(views: [title, subtitle, form, security, errorLabel, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
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
        ])
    }

    @objc private func connect() {
        let draft = InteractiveConnectionDraft(
            coreLibrary: coreField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            rendezvousServer: serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            serverPublicKey: keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            peerID: peerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: passwordField.stringValue,
            forceRelay: relayButton.state == .on
        )
        guard !draft.coreLibrary.isEmpty, !draft.rendezvousServer.isEmpty,
              !draft.serverPublicKey.isEmpty, !draft.peerID.isEmpty else {
            showError("请填写 Core 动态库、Hermes 服务、公钥和远端 ID。")
            return
        }
        connectButton.isEnabled = false
        errorLabel.isHidden = true
        onConnect?(draft)
        passwordField.stringValue = ""
    }
}

final class ViewerChromeView: NSView {
    let videoView: ViewerMetalView
    var onDisconnect: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onToggleKeyboardGrab: (() -> Void)?

    private let hudPanel = NSVisualEffectView()
    private let hudLabel = NSTextField(labelWithString: "正在等待视频…")
    private let stateLabel = NSTextField(labelWithString: "正在连接…")
    private let keyboardStatusLabel = NSTextField(labelWithString: "")
    private let keyboardGrabButton = NSButton(title: "独占键盘", target: nil, action: nil)
    private var hudVisible = true
    private var keyboardGrabActive = false
    private var keyboardGrabAvailable = false
    private weak var metrics: PipelineMetrics?

    init(videoView: ViewerMetalView, metrics: PipelineMetrics) {
        self.videoView = videoView
        self.metrics = metrics
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
        let toolbar = NSStackView(views: [
            stateLabel, NSView(), keyboardStatusLabel, keyboardGrabButton,
            acceptance, hud, fullscreen, disconnect,
        ])
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
        alert.messageText = "Phase 3 人工功能反馈"
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
