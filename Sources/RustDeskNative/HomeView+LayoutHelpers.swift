import AppKit
import ConnectionCatalog

extension HomeView {
    func makeSidebar(versionLabel: NSTextField) -> NSView {
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active

        let brand = NSStackView(
            views: [BrandLogoView(), brandNameLabel()], axis: .horizontal, alignment: .centerY,
            spacing: 10)

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
        let serverWrap = NSStackView(
            views: [serverStatusDot, serverButton], axis: .horizontal, alignment: .centerY,
            spacing: 4)
        serverWrap.wantsLayer = true
        serverWrap.layer?.cornerRadius = 9
        serverWrap.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        serverWrap.edgeInsets = NSEdgeInsets(top: 6, left: 9, bottom: 6, right: 9)

        let statusWrap = NSStackView(
            views: [statusDot, statusLabel, NSView(), versionLabel], axis: .horizontal,
            alignment: .centerY, spacing: 7)

        let separator = makeSeparator()
        let stack = NSStackView(
            views: [brand, navigation, serverTitle, serverWrap, NSView(), separator, statusWrap],
            axis: .vertical, alignment: .leading, spacing: 12)
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

    func sidebarSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return label
    }

    func makePageHeader(title: String, subtitle: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        let stack = NSStackView(
            views: [titleLabel, subtitleLabel], axis: .vertical, alignment: .leading, spacing: 4)
        return stack
    }

    func makePage(content: NSView, scrolls: Bool) -> NSView {
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

    func makeScrollablePage(views: [NSView]) -> NSView {
        let content = FlippedStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 20
        if let first = views.first { content.setCustomSpacing(26, after: first) }
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

    func makePanel(
        content: NSView, emphasized: Bool = false, cornerRadius: CGFloat = 10,
        insets: NSEdgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    ) -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = cornerRadius
        panel.layer?.backgroundColor = HomePalette.panel.cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor =
            (emphasized
            ? HomePalette.accent.withAlphaComponent(0.24) : NSColor.white.withAlphaComponent(0.12))
            .cgColor
        panel.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(
                equalTo: panel.trailingAnchor, constant: -insets.right),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -insets.bottom),
        ])
        return panel
    }

    /// 概览迷你卡：mono 小标题 + 内容行

    func makeHostMiniCard(title: String, content: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        titleLabel.textColor = .tertiaryLabelColor
        let stack = NSStackView(
            views: [titleLabel, content], axis: .vertical, alignment: .leading, spacing: 6)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return makePanel(
            content: stack, insets: NSEdgeInsets(top: 9, left: 12, bottom: 10, right: 12))
    }

    func makeSettingsSection(symbolName: String, title: String, detail: String, content: NSView)
        -> NSView
    {
        let icon = NSImageView(
            image: NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
                ?? NSImage())
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
        let copy = NSStackView(
            views: [titleLabel, detailLabel], axis: .vertical, alignment: .leading, spacing: 3)
        let header = NSStackView(
            views: [icon, copy, NSView()], axis: .horizontal, alignment: .centerY, spacing: 10)
        let section = NSStackView(
            views: [header, content], axis: .vertical, alignment: .leading, spacing: 13)
        header.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        return section
    }

    func makePermissionsPanel() -> NSView {
        permissionSummaryLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        permissionSummaryDetailLabel.font = .systemFont(ofSize: 11)
        permissionSummaryDetailLabel.textColor = .secondaryLabelColor
        let summaryCopy = NSStackView(
            views: [permissionSummaryLabel, permissionSummaryDetailLabel], axis: .vertical,
            alignment: .leading, spacing: 4)
        let refreshButton = NSButton(
            title: "重新检测", target: self, action: #selector(refreshSystemPermissions))
        refreshButton.bezelStyle = .rounded
        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        let summary = NSStackView(
            views: [summaryCopy, NSView(), refreshButton], axis: .horizontal, alignment: .centerY,
            spacing: 12)

        let stack = NSStackView(
            views: [summary, makeSeparator()], axis: .vertical, alignment: .leading, spacing: 0)
        for kind in HomeSystemPermissionKind.allCases {
            let row = HomePermissionRowView(kind: kind)
            row.onOpenSettings = { [weak self] kind in self?.onOpenSystemPermissionSettings?(kind) }
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

    func makeSeparator() -> NSView {
        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.065).cgColor
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    func selectPage(_ page: HomePage) {
        selectedPage = page
        pageTabView.selectTabViewItem(withIdentifier: page.rawValue)
        for (candidate, button) in sidebarButtons { button.isSelected = candidate == page }
        if page == .connections {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedPage == .connections else { return }
                self.window?.makeFirstResponder(self.peerField)
            }
        }
    }

    @objc func sidebarPageChanged(_ sender: HomeSidebarButton) { selectPage(sender.page) }

    @objc func openPermissionsPage() { selectPage(.permissions) }

    @objc func refreshSystemPermissions() { onRefreshSystemPermissions?() }

    func brandNameLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "FarPane")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }
}
