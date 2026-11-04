import AppKit

struct FileTransferCompletion: Equatable {
    let receiving: Bool
    let directory: URL?
    var hasSkippedFiles = false

    var title: String {
        if hasSkippedFiles { return "文件传输完成（部分内容已跳过）" }
        return receiving ? "文件接收成功" : "文件发送成功"
    }
}

/// 完成结果独立于会话状态栏；弹窗只在用户点击后打开本机目录。
final class FileTransferCompletionPresenter {
    private var pending: [(FileTransferCompletion, NSWindow)] = []
    private(set) var activeAlert: NSAlert?
    private let openDirectory: (URL) -> Bool

    init(openDirectory: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openDirectory = openDirectory
    }

    func show(_ completion: FileTransferCompletion, on window: NSWindow) {
        pending.append((completion, window))
        presentNext()
    }

    static func makeAlert(_ completion: FileTransferCompletion) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = completion.title
        alert.informativeText = completion.receiving ? "文件已保存到本机。" : "所选内容已发送到远端。"
        if completion.hasSkippedFiles { alert.informativeText += "部分内容未传输，请核对文件列表。" }
        if completion.receiving, let directory = completion.directory {
            alert.informativeText += "\n保存位置：\(directory.path)"
            alert.addButton(withTitle: "打开所在文件夹")
            alert.addButton(withTitle: "关闭")
        } else {
            alert.addButton(withTitle: "好")
        }
        return alert
    }

    private func presentNext() {
        guard activeAlert == nil, !pending.isEmpty else { return }
        let (completion, window) = pending.removeFirst()
        let alert = Self.makeAlert(completion)
        activeAlert = alert
        if !window.isVisible { window.orderFront(nil) }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeAlert = nil
            if response == .alertFirstButtonReturn, completion.receiving,
                let directory = completion.directory, !self.openDirectory(directory)
            {
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "无法打开所在文件夹"
                failure.informativeText = "文件已接收成功，但保存位置可能已移动或无法访问。\n\(directory.path)"
                failure.addButton(withTitle: "好")
                self.activeAlert = failure
                failure.beginSheetModal(for: window) { [weak self] _ in
                    self?.activeAlert = nil
                    self?.presentNext()
                }
            } else {
                self.presentNext()
            }
        }
    }
}
