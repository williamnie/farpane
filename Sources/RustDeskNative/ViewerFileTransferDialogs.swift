import AppKit

/// Owns exactly one explicit destination selection sheet. FarPane does not
/// retain the selected path after handing the URL to the descriptor owner.
final class ViewerFileTransferDestinationPickerController {
    private var panel: NSOpenPanel?

    func begin(
        on window: NSWindow,
        completion: @escaping (URL?) -> Void
    ) {
        guard panel == nil else {
            completion(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择一个仅当前用户可访问（权限 0700）的接收文件夹。FarPane 不会覆盖已有文件。"
        panel.prompt = "接收到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            let selected = response == .OK ? panel?.url : nil
            self.panel = nil
            completion(selected)
        }
    }

    func cancel() {
        guard let panel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: .cancel)
        } else {
            panel.close()
        }
        self.panel = nil
    }
}

/// Owns one explicit upload-source selection. The returned URLs must be
/// consumed immediately by the descriptor-backed CoreBridge owner; this
/// controller is intentionally not wired to Viewer product UI yet.
final class ViewerFileTransferUploadSourcePickerController {
    private var panel: NSOpenPanel?

    func begin(
        on window: NSWindow,
        completion: @escaping ([URL]?) -> Void
    ) {
        guard panel == nil else {
            completion(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择要发送的文件或文件夹。FarPane 会拒绝符号链接和不安全条目，并忽略文件夹中的隐藏内容。"
        panel.prompt = "选择发送内容"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            let selected = response == .OK ? panel?.urls : nil
            self.panel = nil
            guard let selected, !selected.isEmpty else {
                completion(nil)
                return
            }
            completion(selected)
        }
    }

    func cancel() {
        guard let panel else { return }
        if let parent = panel.sheetParent {
            parent.endSheet(panel, returnCode: .cancel)
        } else {
            panel.close()
        }
        self.panel = nil
    }
}

/// Requests the remote access password only when no Keychain credential is
/// available. The secure field and temporary String are cleared immediately.
final class ViewerFileTransferPasswordPromptController {
    private let passwordField = NSSecureTextField()
    private var alert: NSAlert?

    func begin(
        on window: NSWindow,
        completion: @escaping (String?) -> Void
    ) {
        guard alert == nil else {
            completion(nil)
            return
        }
        passwordField.stringValue = ""
        passwordField.placeholderString = "访问密码"
        passwordField.setAccessibilityLabel("文件传输访问密码")
        passwordField.frame = NSRect(x: 0, y: 0, width: 380, height: 24)

        let alert = NSAlert()
        alert.messageText = "验证远端文件接收"
        alert.informativeText = "文件传输使用与当前远端相同的访问密码；该密码不会因本次操作保存。"
        alert.accessoryView = passwordField
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        self.alert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            var password = self.passwordField.stringValue
            self.passwordField.stringValue = ""
            self.alert = nil
            guard response == .alertFirstButtonReturn, !password.isEmpty else {
                password = ""
                completion(nil)
                return
            }
            completion(password)
            password = ""
        }
        alert.window.initialFirstResponder = passwordField
    }

    func cancel() {
        passwordField.stringValue = ""
        guard let alert else { return }
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .alertSecondButtonReturn)
        } else {
            alert.window.close()
        }
        self.alert = nil
    }
}
