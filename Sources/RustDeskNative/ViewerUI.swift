import AppKit
import VideoPipeline

enum ViewerFileTransferActionDirection {
    case download
    case upload
}

final class ViewerChromeView: NSView {
    private static let hudPreferenceKey = "viewer.session-hud-visible.v1"

    let videoView: ViewerMetalView
    var onDisconnect: (() -> Void)?
    var onToggleFullscreen: (() -> Void)?
    var onToggleKeyboardGrab: (() -> Void)?
    var onFileTransferAction: (() -> Void)?
    var onFileTransferUploadAction: (() -> Void)?
    var onOpenKeyboardPermissions: (() -> Void)?
    var onControlOverlayVisibilityChanged: ((Bool) -> Void)?

    private let collapsedControl = NSVisualEffectView()
    private let collapsedButton = NSButton(title: "●  ⌄", target: nil, action: nil)
    private let controlsPanel = NSVisualEffectView()
    private let hudPanel = NSVisualEffectView()
    private let hudLabel = NSTextField(labelWithString: "正在等待视频…")
    private let stateLabel = NSTextField(labelWithString: "●  正在连接…")
    private let keyboardStatusLabel = NSTextField(labelWithString: "")
    private let keyboardGrabButton = NSButton(title: "独占键盘", target: nil, action: nil)
    private let keyboardPermissionButton = NSButton(title: "权限设置", target: nil, action: nil)
    private let fileTransferButton = NSButton(title: "接收文件", target: nil, action: nil)
    private let fileTransferUploadButton = NSButton(title: "发送文件", target: nil, action: nil)
    private let hudButton = NSButton(title: "显示 HUD", target: nil, action: nil)
    private let fullscreenButton = NSButton(title: "全屏", target: nil, action: nil)
    private let showsAcceptanceControls: Bool
    private let showsFileTransferControls: Bool
    private var hudVisible: Bool
    private var keyboardGrabActive = false
    private var keyboardGrabAvailable = false
    private var fileTransferAvailable = false
    private var fileTransferActive = false
    private var fileTransferCancellable = false
    private var fileTransferDirection: ViewerFileTransferActionDirection?
    private var controlsExpanded = false
    private var controlsPinned = false
    private var pointerInsideControls = false
    private var collapseTimer: Timer?
    private var localMouseMonitor: Any?
    private weak var metrics: PipelineMetrics?

    init(
        videoView: ViewerMetalView,
        metrics: PipelineMetrics,
        showsAcceptanceControls: Bool,
        showsFileTransferControls: Bool
    ) {
        self.videoView = videoView
        self.metrics = metrics
        self.showsAcceptanceControls = showsAcceptanceControls
        self.showsFileTransferControls = showsFileTransferControls
        hudVisible = showsAcceptanceControls
            || UserDefaults.standard.bool(forKey: Self.hudPreferenceKey)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        collapseTimer?.invalidate()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEnterFullScreenNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didExitFullScreenNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowFullscreenChanged),
                name: NSWindow.didEnterFullScreenNotification,
                object: window
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowFullscreenChanged),
                name: NSWindow.didExitFullScreenNotification,
                object: window
            )
        }
        if localMouseMonitor == nil {
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, self.controlsExpanded, !self.controlsPinned,
                      event.window === self.window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.controlsPanel.frame.contains(point) { self.setControlsExpanded(false) }
                return event
            }
        }
        updateFullscreenTitle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: controlsPanel.frame,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInsideControls = true
        collapseTimer?.invalidate()
    }

    override func mouseExited(with event: NSEvent) {
        pointerInsideControls = false
        scheduleCollapse()
    }

    func updateState(_ text: String, isError: Bool = false) {
        stateLabel.stringValue = "●  \(text)"
        stateLabel.textColor = isError ? .systemRed : .labelColor
        collapsedButton.contentTintColor = isError ? .systemRed : .labelColor
        if isError {
            controlsPinned = true
            setControlsExpanded(true)
        }
    }

    func setKeyboardGrabAvailable(_ available: Bool) {
        keyboardGrabAvailable = available
        keyboardGrabButton.isEnabled = available || keyboardGrabActive
    }

    func updateKeyboardGrab(active: Bool, message: String?, isError: Bool) {
        keyboardGrabActive = active
        collapsedButton.title = active ? "⌨︎  ⌄" : "●  ⌄"
        collapsedButton.toolTip = active
            ? "键盘独占已开启；点击打开本地控制"
            : "打开会话控制"
        keyboardGrabButton.title = active ? "退出独占" : "独占键盘"
        keyboardGrabButton.isEnabled = active || keyboardGrabAvailable
        keyboardStatusLabel.stringValue = message ?? ""
        keyboardStatusLabel.textColor = isError ? .systemRed : .systemOrange
        keyboardStatusLabel.isHidden = message?.isEmpty != false
        keyboardPermissionButton.isHidden = !isError
        if isError {
            controlsPinned = true
            setControlsExpanded(true)
        }
    }

    func setFileTransferAvailable(_ available: Bool) {
        fileTransferAvailable = available
        fileTransferButton.isEnabled = fileTransferActive
            ? fileTransferDirection == .download && fileTransferCancellable
            : available
        fileTransferUploadButton.isEnabled = fileTransferActive
            ? fileTransferDirection == .upload && fileTransferCancellable
            : available
    }

    func updateFileTransferAction(
        active: Bool,
        cancellable: Bool = false,
        direction: ViewerFileTransferActionDirection = .download
    ) {
        fileTransferActive = active
        fileTransferCancellable = active && cancellable
        fileTransferDirection = active ? direction : nil
        updateFileTransferButton(
            fileTransferButton,
            direction: .download,
            idleTitle: "接收文件",
            cancelTitle: "取消接收",
            idleToolTip: "选择本机私有目录并接收远端共享文件"
        )
        updateFileTransferButton(
            fileTransferUploadButton,
            direction: .upload,
            idleTitle: "发送文件",
            cancelTitle: "取消发送",
            idleToolTip: "选择本机文件或文件夹并发送到远端"
        )
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

        configureMaterial(collapsedControl, radius: 12)
        collapsedButton.bezelStyle = .inline
        collapsedButton.font = .systemFont(ofSize: 12, weight: .semibold)
        collapsedButton.target = self
        collapsedButton.action = #selector(expandControls)
        collapsedButton.toolTip = "打开会话控制"
        collapsedButton.setAccessibilityLabel("打开会话控制")
        collapsedButton.translatesAutoresizingMaskIntoConstraints = false
        collapsedControl.addSubview(collapsedButton)
        NSLayoutConstraint.activate([
            collapsedButton.leadingAnchor.constraint(equalTo: collapsedControl.leadingAnchor, constant: 8),
            collapsedButton.trailingAnchor.constraint(equalTo: collapsedControl.trailingAnchor, constant: -8),
            collapsedButton.topAnchor.constraint(equalTo: collapsedControl.topAnchor, constant: 3),
            collapsedButton.bottomAnchor.constraint(equalTo: collapsedControl.bottomAnchor, constant: -3),
            collapsedControl.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            collapsedControl.heightAnchor.constraint(equalToConstant: 26),
        ])

        configureMaterial(controlsPanel, radius: 13)
        stateLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        keyboardStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        keyboardStatusLabel.isHidden = true
        keyboardStatusLabel.lineBreakMode = .byTruncatingTail
        keyboardStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        keyboardGrabButton.bezelStyle = .rounded
        keyboardGrabButton.target = self
        keyboardGrabButton.action = #selector(toggleKeyboardGrab)
        keyboardGrabButton.isEnabled = false
        keyboardGrabButton.toolTip = "捕获本机系统快捷键并发送到远端；按 ⌃⌥⇧Esc 退出"
        keyboardPermissionButton.bezelStyle = .inline
        keyboardPermissionButton.target = self
        keyboardPermissionButton.action = #selector(openKeyboardPermissions)
        keyboardPermissionButton.isHidden = true
        fileTransferButton.bezelStyle = .rounded
        fileTransferButton.target = self
        fileTransferButton.action = #selector(fileTransferAction)
        fileTransferButton.isEnabled = false
        fileTransferButton.toolTip = "选择本机私有目录并接收远端共享文件"
        fileTransferButton.setAccessibilityLabel("接收远端文件")
        fileTransferUploadButton.bezelStyle = .rounded
        fileTransferUploadButton.target = self
        fileTransferUploadButton.action = #selector(fileTransferUploadAction)
        fileTransferUploadButton.isEnabled = false
        fileTransferUploadButton.toolTip = "选择本机文件或文件夹并发送到远端"
        fileTransferUploadButton.setAccessibilityLabel("发送文件到远端")
        hudButton.bezelStyle = .rounded
        hudButton.target = self
        hudButton.action = #selector(toggleHUD)
        fullscreenButton.bezelStyle = .rounded
        fullscreenButton.target = self
        fullscreenButton.action = #selector(toggleFullscreen)
        let disconnectButton = actionButton("断开", #selector(disconnect))
        disconnectButton.contentTintColor = .systemRed
        let collapseButton = actionButton("收起", #selector(collapseControls))
        collapseButton.toolTip = "收起会话控制"
        let acceptanceButton = actionButton("验收记录", #selector(showChecklist))

        var views: [NSView] = [stateLabel, keyboardStatusLabel, keyboardPermissionButton, NSView(), keyboardGrabButton]
        if showsFileTransferControls {
            views.append(fileTransferButton)
            views.append(fileTransferUploadButton)
        }
        if showsAcceptanceControls { views.append(acceptanceButton) }
        views.append(contentsOf: [hudButton, fullscreenButton, disconnectButton, collapseButton])
        let controlsStack = NSStackView(views: views)
        controlsStack.orientation = .horizontal
        controlsStack.alignment = .centerY
        controlsStack.spacing = 8
        controlsStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsPanel.addSubview(controlsStack)
        NSLayoutConstraint.activate([
            controlsStack.leadingAnchor.constraint(equalTo: controlsPanel.leadingAnchor),
            controlsStack.trailingAnchor.constraint(equalTo: controlsPanel.trailingAnchor),
            controlsStack.topAnchor.constraint(equalTo: controlsPanel.topAnchor),
            controlsStack.bottomAnchor.constraint(equalTo: controlsPanel.bottomAnchor),
        ])

        configureMaterial(hudPanel, radius: 10)
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

        for overlay in [collapsedControl, controlsPanel, hudPanel] {
            overlay.translatesAutoresizingMaskIntoConstraints = false
            addSubview(overlay)
        }
        NSLayoutConstraint.activate([
            collapsedControl.centerXAnchor.constraint(equalTo: centerXAnchor),
            collapsedControl.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            controlsPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            controlsPanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            controlsPanel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            controlsPanel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            hudPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hudPanel.topAnchor.constraint(equalTo: controlsPanel.bottomAnchor, constant: 10),
        ])
        controlsPanel.isHidden = true
        hudPanel.isHidden = !hudVisible
        updateHUDButtonTitle()
    }

    private func configureMaterial(_ view: NSVisualEffectView, radius: CGFloat) {
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func setControlsExpanded(_ expanded: Bool) {
        guard controlsExpanded != expanded else {
            if expanded { scheduleCollapse() }
            return
        }
        controlsExpanded = expanded
        collapsedControl.isHidden = expanded
        controlsPanel.isHidden = !expanded
        onControlOverlayVisibilityChanged?(expanded)
        layoutSubtreeIfNeeded()
        if expanded, let mouse = window?.mouseLocationOutsideOfEventStream {
            pointerInsideControls = controlsPanel.frame.contains(convert(mouse, from: nil))
        } else if !expanded {
            pointerInsideControls = false
        }
        updateTrackingAreas()
        if expanded { scheduleCollapse() }
        else { collapseTimer?.invalidate() }
    }

    private func scheduleCollapse() {
        collapseTimer?.invalidate()
        guard controlsExpanded, !controlsPinned, !pointerInsideControls else { return }
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.setControlsExpanded(false)
        }
    }

    private func updateHUDButtonTitle() {
        hudButton.title = hudVisible ? "隐藏 HUD" : "显示 HUD"
    }

    private func updateFullscreenTitle() {
        fullscreenButton.title = window?.styleMask.contains(.fullScreen) == true ? "退出全屏" : "全屏"
    }

    @objc private func expandControls() {
        controlsPinned = false
        setControlsExpanded(true)
    }

    @objc private func collapseControls() {
        controlsPinned = false
        setControlsExpanded(false)
    }

    @objc private func toggleFullscreen() {
        metrics?.recordFullscreenToggle()
        onToggleFullscreen?()
        scheduleCollapse()
    }

    @objc private func windowFullscreenChanged() { updateFullscreenTitle() }

    @objc private func toggleHUD() {
        hudVisible.toggle()
        hudPanel.isHidden = !hudVisible
        updateHUDButtonTitle()
        if !showsAcceptanceControls {
            UserDefaults.standard.set(hudVisible, forKey: Self.hudPreferenceKey)
        }
        metrics?.recordHUDToggle()
        scheduleCollapse()
    }

    @objc private func toggleKeyboardGrab() {
        onToggleKeyboardGrab?()
        scheduleCollapse()
    }

    @objc private func openKeyboardPermissions() {
        onOpenKeyboardPermissions?()
        scheduleCollapse()
    }

    @objc private func fileTransferAction() {
        onFileTransferAction?()
        scheduleCollapse()
    }

    @objc private func fileTransferUploadAction() {
        onFileTransferUploadAction?()
        scheduleCollapse()
    }

    @objc private func disconnect() { onDisconnect?() }

    private func updateFileTransferButton(
        _ button: NSButton,
        direction: ViewerFileTransferActionDirection,
        idleTitle: String,
        cancelTitle: String,
        idleToolTip: String
    ) {
        let isActiveDirection = fileTransferActive
            && fileTransferDirection == direction
        button.title = isActiveDirection
            ? (fileTransferCancellable ? cancelTitle : "正在准备…")
            : idleTitle
        button.contentTintColor = isActiveDirection && fileTransferCancellable
            ? .systemOrange
            : nil
        button.isEnabled = isActiveDirection
            ? fileTransferCancellable
            : (!fileTransferActive && fileTransferAvailable)
        button.toolTip = isActiveDirection && fileTransferCancellable
            ? (direction == .download ? "取消当前文件接收" : "取消当前文件发送")
            : idleToolTip
    }

    @objc private func showChecklist() {
        guard let metrics else { return }
        collapseTimer?.invalidate()
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
        guard alert.runModal() == .alertFirstButtonReturn else {
            scheduleCollapse()
            return
        }
        for (key, button) in buttons {
            metrics.recordFunctionalCheck(key, passed: button.state == .on)
        }
        scheduleCollapse()
    }
}
