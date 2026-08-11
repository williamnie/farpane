import AppKit
import CoreBridge

enum HostFileTransferReceiveRootSelectionResult {
    case selected(String)
    case cancelled
    case rejected
}

/// Owns one explicit receive-root selection. The user chooses a parent and
/// FarPane creates/reuses only its fixed private child; no directory listing is
/// performed and no path becomes policy until provisioning succeeds.
final class HostFileTransferReceiveRootPickerController {
    private var panel: NSOpenPanel?

    func begin(
        on window: NSWindow,
        completion: @escaping (
            HostFileTransferReceiveRootSelectionResult
        ) -> Void
    ) {
        guard panel == nil else {
            completion(.rejected)
            return
        }
        let panel = NSOpenPanel()
        panel.message = "选择保存位置。FarPane 将在其中创建或使用专属的 FarPane Receive 私有文件夹（权限 0700）。"
        panel.prompt = "使用此位置"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = false
        self.panel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            let selectedParent = response == .OK ? panel?.url : nil
            self.panel = nil
            guard let selectedParent else {
                completion(.cancelled)
                return
            }
            guard let receiveRoot =
                    HostFileTransferReceiveRootProvisioner.provision(
                        inside: selectedParent
                    )
            else {
                completion(.rejected)
                return
            }
            completion(.selected(receiveRoot.path))
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
