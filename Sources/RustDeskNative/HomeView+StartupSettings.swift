import AppKit

extension HomeView {
    func makeStartupSettings() -> NSView {
        let row = makeToggleRow(
            loginStartupSwitch, title: "开机自启", action: #selector(loginStartupChanged))
        loginStartupSwitch.identifier = NSUserInterfaceItemIdentifier("login-startup")
        loginStartupStatusLabel.font = .systemFont(ofSize: 11)
        loginStartupStatusLabel.textColor = .secondaryLabelColor
        loginStartupSystemSettingsButton.bezelStyle = .inline
        loginStartupSystemSettingsButton.target = self
        loginStartupSystemSettingsButton.action = #selector(openLoginStartupSystemSettings)
        loginStartupSystemSettingsButton.isHidden = true
        let content = NSStackView(
            views: [row, loginStartupStatusLabel, loginStartupSystemSettingsButton],
            axis: .vertical, alignment: .leading, spacing: 6)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        loginStartupStatusLabel.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return makePanel(
            content: makeSettingsSection(
                symbolName: "power", title: "启动", detail: "登录 Mac 后自动打开 FarPane", content: content))
    }

    func applyLoginStartup(_ presentation: LoginStartupPresentation) {
        loginStartupSwitch.state = presentation.isEnabled ? .on : .off
        loginStartupSwitch.isEnabled = presentation.canChange
        loginStartupStatusLabel.stringValue = presentation.message
        loginStartupSystemSettingsButton.isHidden = !presentation.needsApproval
    }

    @objc func loginStartupChanged() {
        guard loginStartupSwitch.isEnabled else { return }
        onLoginStartupToggle?(loginStartupSwitch.state == .on)
    }

    @objc func openLoginStartupSystemSettings() { onOpenLoginStartupSystemSettings?() }
}
