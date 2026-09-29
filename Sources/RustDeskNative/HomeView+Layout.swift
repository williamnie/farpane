import AppKit
import ConnectionCatalog

extension HomeView {
    func configure() {
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor =
            NSColor(calibratedRed: 0.043, green: 0.051, blue: 0.063, alpha: 1).cgColor

        serverStatusDot.wantsLayer = true
        serverStatusDot.layer?.cornerRadius = 4
        serverStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            serverStatusDot.widthAnchor.constraint(equalToConstant: 8),
            serverStatusDot.heightAnchor.constraint(equalToConstant: 8),
        ])

        serverButton.bezelStyle = .inline
        serverButton.image = NSImage(
            systemSymbolName: "gearshape", accessibilityDescription: "服务器设置")
        serverButton.imagePosition = .imageLeading
        serverButton.target = self
        serverButton.action = #selector(openServerSettings)
        serverButton.toolTip = "服务器设置"

        // ---------- 快速连接卡片 ----------
        let viewerAudioRow = makeQuickConnectControls()

        // ---------- 本机 Host ----------
        let (hostIDDetails, hostPasswordDetails, hostPermanentPasswordDetails) =
            makeHostIdentityControls()

        let hostClipboardSettings = makeClipboardSettings()

        let hostFileTransferSettings = makeFileTransferSettings()

        let hostAudioSettings = makeAudioSettings()

        configureSessionBanner()

        configureApprovalBanner()

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
        hostStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let connectionRow = NSStackView(
            views: [peerContainer, connectButton, quickSendFilesButton], axis: .horizontal,
            alignment: .centerY, spacing: 8)

        let connectionColumn = NSStackView(
            views: [connectionRow, viewerAudioRow], axis: .vertical, alignment: .leading, spacing: 8
        )
        connectionRow.widthAnchor.constraint(equalTo: connectionColumn.widthAnchor).isActive = true
        viewerAudioRow.widthAnchor.constraint(equalTo: connectionColumn.widthAnchor).isActive = true

        let quickDivider = NSView()
        quickDivider.wantsLayer = true
        quickDivider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        NSLayoutConstraint.activate([
            quickDivider.widthAnchor.constraint(equalToConstant: 1),
            quickDivider.heightAnchor.constraint(equalToConstant: 46),
        ])

        let hostToggleRow = NSStackView(
            views: [hostToggleTitle, hostStatusDot, hostStatusLabel, NSView(), hostSwitch],
            axis: .horizontal, alignment: .centerY, spacing: 8)

        let quickCard = NSStackView(
            views: [connectionColumn, quickDivider, hostToggleRow], axis: .horizontal,
            alignment: .centerY, spacing: 14)
        connectionColumn.widthAnchor.constraint(equalTo: quickCard.widthAnchor, multiplier: 0.62)
            .isActive = true
        hostToggleRow.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let quickContainer = makePanel(content: quickCard)

        // ---------- 本机概览：三张迷你卡 ----------
        let hostIDCard = makeHostMiniCard(title: "本机 ID", content: hostIDDetails)
        let hostPasswordCard = makeHostMiniCard(title: "临时密码", content: hostPasswordDetails)
        let hostPermanentCard = makeHostMiniCard(
            title: "永久密码", content: hostPermanentPasswordDetails)

        let hostStrip = NSStackView(
            views: [hostIDCard, hostPasswordCard, hostPermanentCard], axis: .horizontal,
            alignment: .top)
        hostStrip.distribution = .fillEqually
        hostStrip.spacing = 8

        // ---------- 系统授权 chip 条 ----------
        let permissionBarTitle = NSTextField(labelWithString: "系统授权")
        permissionBarTitle.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        permissionBarTitle.textColor = .tertiaryLabelColor
        permissionChipsLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        permissionChipsLabel.stringValue = "正在检测…"
        let permissionRefreshButton = NSButton(
            title: "重新检测", target: self, action: #selector(refreshSystemPermissions))
        permissionRefreshButton.bezelStyle = .inline
        permissionRefreshButton.setAccessibilityLabel("重新检测系统授权状态")
        let permissionManageButton = NSButton(
            title: "管理", target: self, action: #selector(openPermissionsPage))
        permissionManageButton.bezelStyle = .inline
        permissionManageButton.setAccessibilityLabel("打开授权与安全页面")
        let permissionBarRow = NSStackView(
            views: [
                permissionBarTitle, permissionChipsLabel, NSView(), permissionRefreshButton,
                permissionManageButton,
            ], axis: .horizontal, alignment: .centerY, spacing: 10)
        let permissionBar = makePanel(
            content: permissionBarRow, insets: NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 12))

        // ---------- Host 动态横幅（会话 / 审批 / 错误，默认隐藏） ----------
        let hostBanner = NSStackView(
            views: [
                hostCopyFeedbackLabel, hostSessionContainer, hostApprovalContainer,
                hostMediaDiagnosticLabel, hostErrorLabel, hostCommandRetryButton,
            ], axis: .vertical, alignment: .leading, spacing: 8)
        for view in hostBanner.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: hostBanner.widthAnchor).isActive = true
        }

        let clipboardSection = makeSettingsSection(
            symbolName: "doc.on.clipboard", title: "剪贴板同步", detail: "按数据类型和方向分别控制",
            content: hostClipboardSettings)
        let audioSection = makeSettingsSection(
            symbolName: "waveform", title: "远程音频", detail: "默认关闭，原生捕获系统音频",
            content: hostAudioSettings)
        let fileSection = makeSettingsSection(
            symbolName: "folder", title: "文件接收", detail: "限定接收根目录并逐次确认",
            content: hostFileTransferSettings)
        let sharingCard = NSStackView(
            views: [clipboardSection, makeSeparator(), audioSection, makeSeparator(), fileSection],
            axis: .vertical, alignment: .leading, spacing: 16)
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
        countBadge.layer?.backgroundColor =
            NSColor.quaternaryLabelColor.withAlphaComponent(0.16).cgColor
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            countBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            countBadge.heightAnchor.constraint(equalToConstant: 18),
        ])

        let recentWrap = NSStackView(
            views: [recentTitle, countBadge], axis: .horizontal, alignment: .centerY, spacing: 6)

        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        searchField.placeholderString = "搜索名称或 ID"
        searchField.delegate = self
        searchField.setContentHuggingPriority(.required, for: .horizontal)
        searchField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let listToolbar = NSStackView(
            views: [recentWrap, NSView(), filterControl, searchField], axis: .horizontal,
            alignment: .centerY, spacing: 12)

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
            listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
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
        let connectionsContent = NSStackView(
            views: [
                makePageHeader(title: "设备", subtitle: "输入远端 ID 发起连接，或从最近连接快速返回。"), quickContainer,
                hostStrip, permissionBar, hostBanner, listToolbar, errorLabel, scrollView,
            ], axis: .vertical, alignment: .leading, spacing: 12)
        connectionsContent.setCustomSpacing(16, after: connectionsContent.arrangedSubviews[0])
        connectionsContent.setCustomSpacing(8, after: listToolbar)
        for view in connectionsContent.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: connectionsContent.widthAnchor).isActive = true
        }
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let connectionsPage = makePage(content: connectionsContent, scrolls: false)

        let permissionContainer = makePermissionsPanel()
        let permissionsPage = makeScrollablePage(views: [
            makePageHeader(title: "授权与安全", subtitle: "读取 macOS 权威状态，并直接打开对应的系统设置页面。"),
            permissionContainer,
        ])

        let settingsPage = makeScrollablePage(views: [
            makePageHeader(title: "共享设置", subtitle: "决定远端会话可以使用哪些本机能力；未开启的能力保持关闭。"),
            sharingContainer,
        ])

        pageTabView.tabViewType = .noTabsNoBorder
        pageTabView.drawsBackground = false
        for (page, view) in [
            (HomePage.connections, connectionsPage), (.permissions, permissionsPage),
            (.sharing, settingsPage),
        ] {
            let item = NSTabViewItem(identifier: page.rawValue)
            item.label = page.title
            item.view = view
            pageTabView.addTabViewItem(item)
        }

        let sidebar = makeSidebar(versionLabel: versionLabel)
        let root = NSStackView(
            views: [sidebar, pageTabView], axis: .horizontal, alignment: .top, spacing: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 208),
            sidebar.heightAnchor.constraint(equalTo: root.heightAnchor),
            pageTabView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -208),
            pageTabView.heightAnchor.constraint(equalTo: root.heightAnchor),
        ])
        selectPage(.connections)
    }
}
