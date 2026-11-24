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
        hostDirectAccessCheckbox.state = settings?.enabled == true ? .on : .off
        hostDirectAccessCheckbox.target = self
        hostDirectAccessCheckbox.action = #selector(directAccessToggled)
        hostDirectAccessPort.stringValue = settings?.port.map(String.init) ?? ""
        hostDirectAccessPort.isEnabled = settings?.enabled == true
        hostDirectAccessPort.setAccessibilityLabel("直连端口")
        hostDirectAccessPort.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let confirm = NSButton(title: "确认", target: self, action: #selector(saveDirectAccess))
        let row = NSStackView(
            views: [NSTextField(labelWithString: "端口"), hostDirectAccessPort, confirm],
            axis: .horizontal, alignment: .centerY, spacing: 8)
        return NSStackView(
            views: [hostDirectAccessCheckbox, row, hostDirectAccessStatus],
            axis: .vertical, alignment: .leading, spacing: 8)
    }

    @objc private func directAccessToggled() {
        hostDirectAccessPort.isEnabled = hostDirectAccessCheckbox.state == .on
        hostDirectAccessStatus.stringValue = ""
    }

    @objc private func saveDirectAccess() {
        let enabled = hostDirectAccessCheckbox.state == .on
        let portText = hostDirectAccessPort.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: UInt16?
        if enabled {
            guard let requestedPort = UInt16(portText), requestedPort > 0 else {
                hostDirectAccessStatus.stringValue = "端口必须为 1 至 65535。"
                return
            }
            port = requestedPort
        } else {
            port = HostDirectAccessSettings.load()?.port
        }

        do {
            try HostDirectAccessSettings(enabled: enabled, port: port).save()
            hostDirectAccessPort.stringValue = port.map(String.init) ?? ""
            hostDirectAccessStatus.stringValue = "设置已保存。"
        } catch {
            hostDirectAccessStatus.stringValue = "无法保存直连设置。"
        }
    }
}
