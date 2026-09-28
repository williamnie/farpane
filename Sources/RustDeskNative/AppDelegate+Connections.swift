import AppKit
import ApplicationServices
import ConnectionCatalog
import CoreBridge
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import MetalKit
import VideoPipeline
import ViewerInput

extension AppDelegate {
    func handleQuickConnect(peerID: String, opensFileTransferUpload: Bool = false) {
        guard activeAttemptID == nil else { return }
        guard catalog.server?.isComplete == true else {
            homeErrorText = "请先配置 RustDesk ID 服务器和服务器公钥。"
            refreshHomeUI()
            presentServerSettings()
            return
        }
        if let device = catalog.device(peerID: peerID) {
            connectSavedDevice(device, opensFileTransferUpload: opensFileTransferUpload)
        } else {
            promptForPassword(
                deviceID: nil, peerID: DeviceCatalogDocument.normalize(peerID),
                saveByDefault: false, message: "输入远端设备的访问密码。认证成功后会加入最近连接。",
                opensFileTransferUpload: opensFileTransferUpload)
        }
    }

    func connectSavedDevice(_ device: SavedDevice, opensFileTransferUpload: Bool = false) {
        do {
            if let password = try credentialStore.read(deviceID: device.id), !password.isEmpty {
                startProductConnection(
                    deviceID: device.id, deviceExisted: true, peerID: device.peerID,
                    password: password, savePassword: false, usedStoredCredential: true,
                    opensFileTransferUpload: opensFileTransferUpload)
            } else {
                promptForPassword(
                    deviceID: device.id, peerID: device.peerID, saveByDefault: false,
                    message: "这台设备没有保存密码，请输入本次连接使用的密码。",
                    opensFileTransferUpload: opensFileTransferUpload)
            }
        } catch {
            promptForPassword(
                deviceID: device.id, peerID: device.peerID, saveByDefault: false,
                message: "无法读取已保存密码，请手动输入。", opensFileTransferUpload: opensFileTransferUpload)
        }
    }

    func promptForPassword(
        deviceID: UUID?, peerID: String, saveByDefault: Bool, message: String,
        receiveAudio: Bool? = nil, opensFileTransferUpload: Bool = false
    ) {
        guard activeAttemptID == nil, let window else { return }
        let prompt = PasswordPromptController()
        passwordPrompt = prompt
        prompt.begin(
            on: window, title: "连接 \(formattedPeerID(peerID))", message: message,
            saveByDefault: saveByDefault
        ) { [weak self, weak prompt] result in
            guard let self else { return }
            if self.passwordPrompt === prompt { self.passwordPrompt = nil }
            guard let result else { return }
            self.startProductConnection(
                deviceID: deviceID ?? UUID(), deviceExisted: deviceID != nil, peerID: peerID,
                password: result.password, savePassword: result.saveToKeychain,
                usedStoredCredential: false, receiveAudio: receiveAudio,
                opensFileTransferUpload: opensFileTransferUpload)
        }
    }

    func startProductConnection(
        deviceID: UUID, deviceExisted: Bool, peerID: String, password: String, savePassword: Bool,
        usedStoredCredential: Bool, receiveAudio requestedReceiveAudio: Bool? = nil,
        opensFileTransferUpload: Bool = false
    ) {
        guard activeAttemptID == nil, let server = catalog.server, server.isComplete else { return }
        let receiveAudio = requestedReceiveAudio ?? viewerAudioOptInForNextConnection
        if hostRuntimeActive || hostClient != nil || !hostRuntimeQuiescenceConfirmed {
            guard stopHostMode(preservePreference: true, reason: .userRequest, releaseClient: true)
            else {
                homeErrorText = "无法确认被控端已停止，已取消本次连接；请重新启动 FarPane 后重试。"
                refreshHomeUI()
                return
            }
        }
        let attemptID = UUID()
        viewerAudioOptInForNextConnection = false
        viewerSessionReceiveAudio = receiveAudio
        viewerOpenFileTransferUploadWhenStreaming = opensFileTransferUpload
        activeAttemptID = attemptID
        viewerRecoveryDeviceID = deviceID
        pendingProductConnection = PendingProductConnection(
            attemptID: attemptID, deviceID: deviceID, deviceExisted: deviceExisted, peerID: peerID,
            password: password, savePassword: savePassword,
            usedStoredCredential: usedStoredCredential, receiveAudio: receiveAudio)
        homeErrorText = ""
        refreshHomeUI()

        do {
            let coreURL = URL(fileURLWithPath: defaultCorePath())
            guard FileManager.default.fileExists(atPath: coreURL.path) else {
                throw usageError("bundled Core is unavailable")
            }
            let configuration = CoreConnectionConfig(
                rendezvousServer: server.rendezvousServer, serverPublicKey: server.serverPublicKey,
                peerID: peerID, password: password, forceRelay: server.forceRelay,
                receiveAudio: receiveAudio, receiveClipboardText: true, sendClipboardText: true,
                receiveClipboardRichText: true, sendClipboardRichText: true,
                receiveClipboardImage: true, sendClipboardImage: true)
            try launchViewer(
                fixture: nil, liveConfiguration: (coreURL, configuration), attemptID: attemptID)
        } catch {
            activeAttemptID = nil
            pendingProductConnection?.password = ""
            pendingProductConnection = nil
            showHomeUI(error: sanitizedStartupError(error))
        }
    }

    func handleAuthenticated(attemptID: UUID) {
        guard activeAttemptID == attemptID, var pending = pendingProductConnection,
            pending.attemptID == attemptID
        else { return }
        var updated = catalog
        let device = updated.recordAuthenticated(
            peerID: pending.peerID, preferredID: pending.deviceID)
        do {
            if pending.savePassword {
                try credentialStore.upsert(pending.password, deviceID: device.id)
            }
            try catalogStore.save(updated)
            catalog = updated
            reconcileHostAgentBootstrap()
            homeErrorText = ""
        } catch {
            if pending.savePassword, !pending.deviceExisted {
                try? credentialStore.delete(deviceID: device.id)
            }
            presentNonFatalWarning(title: "已连接，但保存失败", message: "设备或密码未能安全保存；本次会话仍可继续使用。")
        }
        pending.password = ""
        pendingProductConnection = nil
    }

    func handleTerminalState(_ event: CoreStateEvent, attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        let retryDeviceID = pendingProductConnection?.deviceID
        let retryDeviceExisted = pendingProductConnection?.deviceExisted ?? false
        let retryPeerID = pendingProductConnection?.peerID
        let retrySaveByDefault =
            pendingProductConnection.map { $0.savePassword || $0.usedStoredCredential } ?? false
        let retryReceiveAudio = pendingProductConnection?.receiveAudio ?? false
        let retryOpenFileTransferUpload = viewerOpenFileTransferUploadWhenStreaming
        let shouldRetryPassword =
            event.state == .passwordRequired || event.state == .authenticationFailed
        activeAttemptID = nil
        showHomeUI(error: Self.connectionStateText(event))
        guard shouldRetryPassword, let retryDeviceID, let retryPeerID else { return }
        DispatchQueue.main.async { [weak self] in
            self?.promptForPassword(
                deviceID: retryDeviceExisted ? retryDeviceID : nil, peerID: retryPeerID,
                saveByDefault: retrySaveByDefault, message: "已保存或刚输入的密码不可用，请重新输入。认证成功后才会更新钥匙串。",
                receiveAudio: retryReceiveAudio,
                opensFileTransferUpload: retryOpenFileTransferUpload)
        }
    }

    func handleDeviceAction(deviceID: UUID, action: HomeDeviceAction) {
        guard activeAttemptID == nil, let device = catalog.device(id: deviceID) else { return }
        switch action {
        case .connect: connectSavedDevice(device)
        case .sendFiles: connectSavedDevice(device, opensFileTransferUpload: true)
        case .toggleFavorite:
            var updated = catalog
            _ = updated.updateDevice(id: deviceID, isFavorite: !device.isFavorite)
            commitCatalog(updated)
        case .rename: presentRename(device)
        case .updatePassword:
            promptForPassword(
                deviceID: device.id, peerID: device.peerID, saveByDefault: true,
                message: "输入新密码并连接。只有认证成功后才会更新钥匙串。")
        case .deletePassword:
            do {
                try credentialStore.delete(deviceID: deviceID)
                homeErrorText = ""
            } catch { homeErrorText = "无法删除钥匙串密码，请稍后重试。" }
            refreshHomeUI()
        case .deleteDevice: presentDeleteConfirmation(device)
        }
    }

    func presentRename(_ device: SavedDevice) {
        guard let window else { return }
        let field = NSTextField(string: device.displayName ?? "")
        field.placeholderString = formattedPeerID(device.peerID)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        let alert = NSAlert()
        alert.messageText = "重命名设备"
        alert.informativeText = formattedPeerID(device.peerID)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var updated = self.catalog
            _ = updated.updateDevice(id: device.id, displayName: field.stringValue)
            self.commitCatalog(updated)
        }
        alert.window.initialFirstResponder = field
    }

    func presentDeleteConfirmation(_ device: SavedDevice) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 \(device.resolvedDisplayName)？"
        alert.informativeText = "设备记录和本应用保存的密码会从这台 Mac 删除，此操作无法撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            do {
                try self.credentialStore.delete(deviceID: device.id)
                var updated = self.catalog
                _ = updated.removeDevice(id: device.id)
                try self.catalogStore.save(updated)
                self.catalog = updated
                self.reconcileHostAgentBootstrap()
                self.homeErrorText = ""
            } catch { self.homeErrorText = "设备未删除：无法安全清理本地记录或钥匙串密码。" }
            self.refreshHomeUI()
        }
    }

    func presentServerSettings() {
        guard activeAttemptID == nil, let window else { return }
        if catalogMutationBlocked {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "重建设备列表？"
            alert.informativeText = "当前目录无法读取。应用会先保存损坏文件副本，再创建新的空列表。"
            alert.addButton(withTitle: "备份并重建")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                do {
                    _ = try self.catalogStore.backupCorruptDocument()
                    let empty = DeviceCatalogDocument()
                    try self.catalogStore.save(empty)
                    self.catalog = empty
                    self.catalogMutationBlocked = false
                    self.reconcileHostAgentBootstrap()
                    self.homeErrorText = ""
                    self.refreshHomeUI()
                    self.presentServerSettings()
                } catch {
                    self.homeErrorText = "无法备份并重建设备列表。"
                    self.refreshHomeUI()
                }
            }
            return
        }

        let prompt = ServerSettingsPromptController()
        serverPrompt = prompt
        prompt.begin(on: window, current: catalog.server, affectedDevices: catalog.devices.count) {
            [weak self, weak prompt] configuration in
            guard let self else { return }
            if self.serverPrompt === prompt { self.serverPrompt = nil }
            guard let configuration else { return }
            var updated = self.catalog
            updated.server = configuration
            self.commitCatalog(updated)
            self.homeView?.focusQuickConnect()
        }
    }

    func commitCatalog(_ updated: DeviceCatalogDocument) {
        guard !catalogMutationBlocked else { return }
        let serverChanged = catalog.server != updated.server
        do {
            try catalogStore.save(updated)
            catalog = updated
            reconcileHostAgentBootstrap()
            reconcileHostProductOwnership()
            homeErrorText = ""
            if serverChanged, UserDefaults.standard.bool(forKey: Self.hostEnabledDefaultsKey) {
                if stopHostMode(preservePreference: true, reason: .userRequest) { startHostMode() }
            }
        } catch { homeErrorText = "本地设备列表保存失败，请检查磁盘权限后重试。" }
        refreshHomeUI()
    }

    func presentNonFatalWarning(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: window)
    }

    func formattedPeerID(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.allSatisfy(\.isNumber) else { return value }
        return stride(from: 0, to: compact.count, by: 3).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(3, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: " ")
    }
}
