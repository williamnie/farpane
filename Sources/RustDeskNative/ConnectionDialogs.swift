import AppKit
import ConnectionCatalog
import CoreBridge

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

/// Single-owner mutable transport for a Host permanent password. AppKit's
/// secure text field controls its own internal storage, but FarPane never
/// keeps an additional String property: the explicit UTF-8 transfer buffer is
/// wiped by HostControlClient and again on this object's teardown.
final class HostPermanentPasswordSecret {
    var data = Data()

    func wipe() {
        if !data.isEmpty {
            data.resetBytes(in: 0..<data.count)
        }
    }

    deinit { wipe() }
}

final class HostPermanentPasswordPromptController {
    private let passwordField = NSSecureTextField()
    private let confirmationField = NSSecureTextField()
    private var alert: NSAlert?

    func begin(
        on window: NSWindow,
        policy: HostPermanentPasswordPolicy,
        completion: @escaping (HostPermanentPasswordSecret?) -> Void
    ) {
        passwordField.stringValue = ""
        confirmationField.stringValue = ""
        passwordField.placeholderString = "输入永久密码"
        confirmationField.placeholderString = "再次输入"
        passwordField.setAccessibilityLabel("永久密码")
        confirmationField.setAccessibilityLabel("确认永久密码")

        let form = NSGridView(views: [
            [NSTextField(labelWithString: "永久密码"), passwordField],
            [NSTextField(labelWithString: "确认密码"), confirmationField],
        ])
        form.rowSpacing = 10
        form.columnSpacing = 12
        form.column(at: 0).xPlacement = .trailing
        form.column(at: 1).width = 360

        let hint = NSTextField(wrappingLabelWithString:
            "使用 \(policy.minimumCharacters)–\(policy.maximumCharacters) 个字符，最多 "
                + "\(policy.maximumUTF8Bytes) 个 UTF-8 字节；首尾不能是空白字符。"
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [form, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.frame = NSRect(x: 0, y: 0, width: 470, height: 84)

        let alert = NSAlert()
        alert.messageText = policy.localPasswordSet ? "更改永久密码" : "设置永久密码"
        alert.informativeText = "密码只会送入本机 Host Core，并保存为不可读回的验证数据。"
        alert.accessoryView = stack
        alert.addButton(withTitle: policy.localPasswordSet ? "更改" : "设置")
        alert.addButton(withTitle: "取消")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let secret = HostPermanentPasswordSecret()
            secret.data.append(contentsOf: self.passwordField.stringValue.utf8)
            var confirmation = Data(self.confirmationField.stringValue.utf8)
            self.passwordField.stringValue = ""
            self.confirmationField.stringValue = ""
            self.alert = nil
            defer {
                if !confirmation.isEmpty {
                    confirmation.resetBytes(in: 0..<confirmation.count)
                }
            }
            guard response == .alertFirstButtonReturn else {
                secret.wipe()
                completion(nil)
                return
            }
            guard !secret.data.isEmpty, secret.data == confirmation else {
                secret.wipe()
                self.showValidationError(on: window, policy: policy, completion: completion)
                return
            }
            completion(secret)
        }
        alert.window.initialFirstResponder = passwordField
    }

    private func showValidationError(
        on window: NSWindow,
        policy: HostPermanentPasswordPolicy,
        completion: @escaping (HostPermanentPasswordSecret?) -> Void
    ) {
        let error = NSAlert()
        error.alertStyle = .warning
        error.messageText = "两次输入不一致"
        error.informativeText = "请重新输入并确认永久密码。"
        error.addButton(withTitle: "返回")
        error.beginSheetModal(for: window) { [weak self] _ in
            self?.begin(on: window, policy: policy, completion: completion)
        }
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
