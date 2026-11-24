import AppKit

private struct HostDirectAccessSettings: Codable {
    let enabled: Bool
    let port: UInt16?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/io.rustdesknative.FarPaneHost")
            .appendingPathComponent("direct-access.json")
    }

    static func load() -> Self? {
        guard let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Self.self, from: data),
            settings.port != 0,
            !settings.enabled || settings.port != nil
        else { return nil }
        return settings
    }

    func save() throws {
        try FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

extension HomeView {
    func makeDirectAccessSettings() -> NSView {
        let settings = HostDirectAccessSettings.load()
        hostDirectAccessSwitch.state = settings?.enabled == true ? .on : .off
        hostDirectAccessSwitch.target = self
        hostDirectAccessSwitch.action = #selector(directAccessToggled)
        hostDirectAccessSwitch.setAccessibilityLabel("允许 IP 直连")
        hostDirectAccessPort.stringValue = settings?.port.map(String.init) ?? ""
        hostDirectAccessPort.target = self
        hostDirectAccessPort.action = #selector(applyDirectAccessPort)
        hostDirectAccessPort.placeholderString = "21118"
        hostDirectAccessPort.setAccessibilityLabel("直连端口")
        hostDirectAccessPort.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let portLabel = NSTextField(labelWithString: "端口")
        portLabel.font = .systemFont(ofSize: 12)
        portLabel.textColor = .secondaryLabelColor
        let portRow = NSStackView(
            views: [portLabel, hostDirectAccessPort, hostDirectAccessStatus],
            axis: .horizontal, alignment: .centerY, spacing: 8)
        return NSStackView(views: [portRow], axis: .vertical, alignment: .leading)
    }

    @objc private func applyDirectAccessPort() {
        guard hostDirectAccessSwitch.state == .on else { return }
        saveDirectAccess(switchChanged: false)
    }

    @objc private func directAccessToggled() {
        saveDirectAccess(switchChanged: true)
    }

    private func saveDirectAccess(switchChanged: Bool) {
        let enabled = hostDirectAccessSwitch.state == .on
        let portText = hostDirectAccessPort.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: UInt16?
        if enabled {
            guard let requestedPort = UInt16(portText), requestedPort > 0 else {
                if switchChanged { hostDirectAccessSwitch.state = .off }
                hostDirectAccessStatus.stringValue = "请输入 1 至 65535 的端口。"
                window?.makeFirstResponder(hostDirectAccessPort)
                return
            }
            port = requestedPort
        } else {
            port = HostDirectAccessSettings.load()?.port
        }

        do {
            try HostDirectAccessSettings(enabled: enabled, port: port).save()
            if enabled { hostDirectAccessPort.stringValue = port.map(String.init) ?? "" }
            hostDirectAccessStatus.stringValue = "设置已保存。"
        } catch {
            if switchChanged { hostDirectAccessSwitch.state = enabled ? .off : .on }
            hostDirectAccessStatus.stringValue = "无法保存直连设置。"
        }
    }
}
