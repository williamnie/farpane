import AppKit
import ConnectionCatalog

struct PasswordPromptResult {
    let password: String
    let saveToKeychain: Bool
}

final class PasswordPromptController {
    private let passwordField = NSSecureTextField()
    private let saveButton = NSButton(
        checkboxWithTitle: "保存到此 Mac 的钥匙串",
        target: nil,
        action: nil
    )
    private var alert: NSAlert?

    func begin(
        on window: NSWindow,
        title: String,
        message: String,
        saveByDefault: Bool,
        completion: @escaping (PasswordPromptResult?) -> Void
    ) {
        passwordField.stringValue = ""
        passwordField.placeholderString = "访问密码"
        passwordField.setAccessibilityLabel("访问密码")
        saveButton.state = saveByDefault ? .on : .off

        let help = NSTextField(
            wrappingLabelWithString: "仅建议保存固定密码；一次性密码请保持关闭。"
        )
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [passwordField, saveButton, help])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 92)
        passwordField.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = stack
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let value = self.passwordField.stringValue
            let shouldSave = self.saveButton.state == .on
            self.passwordField.stringValue = ""
            self.alert = nil
            guard response == .alertFirstButtonReturn, !value.isEmpty else {
                completion(nil)
                return
            }
            completion(PasswordPromptResult(password: value, saveToKeychain: shouldSave))
        }
        alert.window.initialFirstResponder = passwordField
    }
}

final class ServerSettingsPromptController {
    private let nameField = NSTextField()
    private let serverField = NSTextField()
    private let keyField = NSTextField()
    private let relayButton = NSButton(
        checkboxWithTitle: "始终通过中继连接",
        target: nil,
        action: nil
    )
    private var alert: NSAlert?

    func begin(
        on window: NSWindow,
        current: ServerConfiguration?,
        affectedDevices: Int,
        completion: @escaping (ServerConfiguration?) -> Void
    ) {
        nameField.stringValue = current?.displayName ?? "自建服务器"
        serverField.stringValue = current?.rendezvousServer ?? ""
        keyField.stringValue = current?.serverPublicKey ?? ""
        relayButton.state = current?.forceRelay == true ? .on : .off
        nameField.placeholderString = "服务器名称"
        serverField.placeholderString = "例如 rustdesk.example.com:21116"
        keyField.placeholderString = "服务器公钥"

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "名称"), nameField],
            [NSTextField(labelWithString: "ID 服务器"), serverField],
            [NSTextField(labelWithString: "服务器公钥"), keyField],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 390
        let impact = NSTextField(
            wrappingLabelWithString: affectedDevices > 0
                ? "修改后会用于列表中的 \(affectedDevices) 台设备。中继地址由 RustDesk Core 自动发现。"
                : "中继地址由 RustDesk Core 自动发现。"
        )
        impact.font = .systemFont(ofSize: 11)
        impact.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [form, relayButton, impact])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.frame = NSRect(x: 0, y: 0, width: 500, height: 138)

        let alert = NSAlert()
        alert.messageText = current == nil ? "配置 RustDesk 服务器" : "服务器设置"
        alert.informativeText = "设备列表只保存连接信息，不会修改官方 RustDesk 的配置。"
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.alert = nil }
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            let trimmedName = self.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let configuration = ServerConfiguration(
                displayName: trimmedName.isEmpty ? "自建服务器" : trimmedName,
                rendezvousServer: self.serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                serverPublicKey: self.keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forceRelay: self.relayButton.state == .on
            )
            guard configuration.isComplete else {
                self.showValidationError(on: window, current: current, affectedDevices: affectedDevices, completion: completion)
                return
            }
            completion(configuration)
        }
        alert.window.initialFirstResponder = serverField
    }

    private func showValidationError(
        on window: NSWindow,
        current: ServerConfiguration?,
        affectedDevices: Int,
        completion: @escaping (ServerConfiguration?) -> Void
    ) {
        let error = NSAlert()
        error.alertStyle = .warning
        error.messageText = "服务器配置不完整"
        error.informativeText = "请填写 RustDesk ID 服务器和服务器公钥。"
        error.addButton(withTitle: "返回")
        error.beginSheetModal(for: window) { [weak self] _ in
            self?.begin(on: window, current: current, affectedDevices: affectedDevices, completion: completion)
        }
    }
}
