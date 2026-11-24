import AppKit
import ConnectionCatalog

private struct HostDirectAccessSettings: Codable {
    let enabled: Bool
    let port: UInt16?

    static var url: URL {
        typealias Namespace = HostAgentBootstrapConfiguration.HostConfigNamespace
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(Namespace.organization).\(Namespace.appName)")
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
    func refreshDirectAccessStatus(_ status: String?, hostRunning: Bool) {
        guard !hostDirectAccessHasInputError, hostDirectAccessSwitch.state == .on,
            let port = HostDirectAccessSettings.load()?.port
        else { return }
        switch status {
        case "listening:\(port)": hostDirectAccessStatus.stringValue = "正在监听 127.0.0.1:\(port)"
        case "portInUse:\(port)": hostDirectAccessStatus.stringValue = "端口已被占用"
        case "bindFailed:\(port)": hostDirectAccessStatus.stringValue = "无法监听端口"
        case nil:
            hostDirectAccessStatus.stringValue = hostRunning ? "等待 Host 监听 127.0.0.1:\(port)" : "等待 Host 启动"
        default: hostDirectAccessStatus.stringValue = "正在应用端口 \(port)"
        }
    }

    func makeDirectAccessSettings() -> NSView {
        let settings = HostDirectAccessSettings.load()
        hostDirectAccessSwitch.state = settings?.enabled == true ? .on : .off
        hostDirectAccessSwitch.target = self
        hostDirectAccessSwitch.action = #selector(directAccessToggled)
        hostDirectAccessSwitch.setAccessibilityLabel("允许本机代理或隧道接入")
        hostDirectAccessPort.stringValue = settings?.port.map(String.init) ?? ""
        hostDirectAccessPort.target = self
        hostDirectAccessPort.action = #selector(applyDirectAccessPort)
        hostDirectAccessPort.cell?.sendsActionOnEndEditing = true
        hostDirectAccessPort.placeholderString = "21118"
        hostDirectAccessPort.setAccessibilityLabel("本机监听端口")
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
        hostDirectAccessHasInputError = false
        let enabled = hostDirectAccessSwitch.state == .on
        let savedPort = HostDirectAccessSettings.load()?.port
        let portText = hostDirectAccessPort.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: UInt16?
        if enabled {
            guard let requestedPort = UInt16(portText), requestedPort > 0 else {
                if switchChanged { hostDirectAccessSwitch.state = .off }
                hostDirectAccessHasInputError = true
                hostDirectAccessStatus.stringValue = "请输入 1 至 65535 的端口。"
                if !switchChanged { hostDirectAccessPort.stringValue = savedPort.map(String.init) ?? "" }
                return
            }
            port = requestedPort
        } else {
            port = savedPort
        }

        if !switchChanged, port == savedPort { return }

        do {
            try HostDirectAccessSettings(enabled: enabled, port: port).save()
            if enabled { hostDirectAccessPort.stringValue = port.map(String.init) ?? "" }
            hostDirectAccessStatus.stringValue = enabled ? "等待 Host 监听" : "已关闭本机接入"
        } catch {
            hostDirectAccessHasInputError = true
            if switchChanged { hostDirectAccessSwitch.state = enabled ? .off : .on }
            else { hostDirectAccessPort.stringValue = savedPort.map(String.init) ?? "" }
            hostDirectAccessStatus.stringValue = "无法保存接入设置。"
        }
    }
}
