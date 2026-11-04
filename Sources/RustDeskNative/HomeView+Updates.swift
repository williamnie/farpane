import AppKit

extension HomeView {
    func makeUpdateSettings() -> NSView {
        let row = makeToggleRow(
            automaticUpdatesSwitch, title: "自动检查新版本", action: #selector(automaticUpdatesChanged))
        automaticUpdatesSwitch.identifier = NSUserInterfaceItemIdentifier("automatic-updates")
        updateStatusLabel.font = .systemFont(ofSize: 11)
        updateStatusLabel.textColor = .secondaryLabelColor
        checkUpdatesButton.bezelStyle = .rounded
        checkUpdatesButton.target = self
        checkUpdatesButton.action = #selector(checkForUpdates)
        openReleaseButton.bezelStyle = .inline
        openReleaseButton.target = self
        openReleaseButton.action = #selector(openReleasePage)
        updateNoticeButton.bezelStyle = .inline
        updateNoticeButton.font = .systemFont(ofSize: 11, weight: .medium)
        updateNoticeButton.contentTintColor = HomePalette.accent
        updateNoticeButton.target = self
        updateNoticeButton.action = #selector(openReleasePage)
        updateNoticeButton.isHidden = true
        updateNoticeButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNoticeButton.cell?.lineBreakMode = .byTruncatingTail
        let actions = NSStackView(
            views: [checkUpdatesButton, openReleaseButton], axis: .horizontal, alignment: .centerY,
            spacing: 10)
        let content = NSStackView(
            views: [row, updateStatusLabel, actions], axis: .vertical, alignment: .leading,
            spacing: 8)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        updateStatusLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return makePanel(
            content: makeSettingsSection(
                symbolName: "arrow.down.circle", title: "软件更新",
                detail: version.map { "当前版本 v\($0) · 包含预览版" } ?? "检查可下载的新版本（包含预览版）",
                content: content))
    }

    @MainActor func applyUpdateChecker(_ checker: ReleaseUpdateChecker) {
        automaticUpdatesSwitch.state = checker.automaticEnabled ? .on : .off
        updateStatusLabel.stringValue = checker.statusText
        checkUpdatesButton.isEnabled = !checker.isChecking
        checkUpdatesButton.title = checker.isChecking ? "正在检查…" : "检查更新"
        openReleaseButton.title = checker.availableUpdate == nil ? "打开发布页" : "下载新版本…"
        updateNoticeButton.isHidden = checker.availableUpdate == nil
        if let update = checker.availableUpdate {
            updateNoticeButton.title = "有新版本 \(update.tag)"
            updateNoticeButton.toolTip = "发现新版本 \(update.tag)，点击前往发布页下载。"
            updateNoticeButton.setAccessibilityLabel(updateNoticeButton.toolTip)
        }
    }

    @objc func automaticUpdatesChanged() {
        onAutomaticUpdatesToggle?(automaticUpdatesSwitch.state == .on)
    }

    @objc func checkForUpdates() { onCheckForUpdates?() }
    @objc func openReleasePage() { onOpenReleasePage?() }
}
