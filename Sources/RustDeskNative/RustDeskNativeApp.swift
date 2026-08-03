import AppKit
import ConnectionCatalog
import CoreBridge
import Darwin
import Foundation
import MetalKit
import VideoPipeline
import ViewerInput

private final class CoreRecoveryCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private weak var client: RustDeskCoreClient?

    func attach(_ client: RustDeskCoreClient) {
        lock.lock(); defer { lock.unlock() }
        self.client = client
    }

    func requestKeyframe(display: UInt32) -> Bool {
        lock.lock()
        let client = self.client
        lock.unlock()
        return client?.requestKeyframe(display: display) == true
    }
}

// The filename intentionally differs from main.swift so Xcode and SwiftPM both
// treat the @main application delegate as the single executable entry point.

private struct Options {
    var fixture: String?
    var coreLibrary: String?
    var serverEnvironment = "RDN_SERVER"
    var keyEnvironment = "RDN_SERVER_PUBLIC_KEY"
    var peerIDEnvironment = "RDN_PEER_ID"
    var passwordEnvironment = "RDN_PASSWORD"
    var forceRelay = false
    var width = 0
    var height = 0
    var fps = 30.0
    var duration = 600.0
    var output = "Benchmarks/latest.json"
    var gpu = GPUPreference.automatic
    var fullscreen = false

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let key = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch key {
            case "--fixture": fixture = value
            case "--core": coreLibrary = value
            case "--server-env": serverEnvironment = value
            case "--key-env": keyEnvironment = value
            case "--peer-id-env": peerIDEnvironment = value
            case "--password-env": passwordEnvironment = value
            case "--force-relay": forceRelay = value != "false"
            case "--width": width = Int(value) ?? 0
            case "--height": height = Int(value) ?? 0
            case "--fps": fps = Double(value) ?? 30
            case "--duration": duration = Double(value) ?? 600
            case "--output": output = value
            case "--gpu": gpu = GPUPreference(rawValue: value) ?? .automatic
            case "--fullscreen": fullscreen = value != "false"
            case "--help":
                print("Fixture: RustDeskNative --fixture FILE --width PX --height PX [--fps 30] [--duration 600] [--gpu automatic|low-power|high-performance] [--fullscreen true|false] [--output FILE]")
                print("Live: set RDN_SERVER/RDN_SERVER_PUBLIC_KEY/RDN_PEER_ID and run RustDeskNative --core DYLIB [--password-env RDN_PASSWORD] [--force-relay true|false] [--duration 1800] [--output FILE]")
                exit(0)
            default: index -= 1
            }
            index += 2
        }
    }
}

private struct PendingProductConnection {
    let attemptID: UUID
    let deviceID: UUID
    let deviceExisted: Bool
    let peerID: String
    var password: String
    let savePassword: Bool
    let usedStoredCredential: Bool
}

@main
private final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let options = Options(arguments: CommandLine.arguments)
    private let catalogStore = DeviceCatalogStore(fileURL: AppDelegate.catalogURL())
    private let credentialStore: DeviceCredentialStore = KeychainDeviceCredentialStore(
        service: ProcessInfo.processInfo.environment["RDN_KEYCHAIN_SERVICE"]
            ?? KeychainDeviceCredentialStore.defaultService
    )
    private var catalog = DeviceCatalogDocument()
    private var catalogMutationBlocked = false
    private var homeErrorText = ""
    private var activeAttemptID: UUID?
    private var pendingProductConnection: PendingProductConnection?
    private var window: NSWindow?
    private var homeView: HomeView?
    private var passwordPrompt: PasswordPromptController?
    private var serverPrompt: ServerSettingsPromptController?
    private var viewerChrome: ViewerChromeView?
    private var viewerView: ViewerMetalView?
    private var renderer: MetalVideoRenderer?
    private var player: FixturePlayer?
    private var liveDecoder: LiveHEVCDecoder?
    private var coreClient: RustDeskCoreClient?
    private var keyboardController: ExclusiveKeyboardController?
    private var metrics: PipelineMetrics?
    private var memoryTimer: Timer?
    private var hudTimer: Timer?
    private var stopTimer: Timer?
    private var startedAt = Date()
    private var didFinish = false
    private var automatedRun = false

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    private static func catalogURL() -> URL {
        guard let override = ProcessInfo.processInfo.environment["RDN_CATALOG_PATH"],
              !override.isEmpty else { return DeviceCatalogStore.defaultFileURL() }
        return URL(fileURLWithPath: override, isDirectory: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try launch()
        } catch {
            fputs("RustDeskNative startup failed: \(error)\n", stderr)
            exit(2)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        finish()
    }

    func applicationDidResignActive(_ notification: Notification) {
        keyboardController?.suspend(
            message: "应用失去焦点，已暂时释放键盘；返回后自动恢复独占"
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        keyboardController?.resumeIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func launch() throws {
        if options.fixture == nil, options.coreLibrary == nil {
            prepareProductCatalog()
            showHomeUI(error: homeErrorText)
            return
        }
        automatedRun = true
        let liveConfiguration = options.fixture == nil ? try environmentConnectionConfiguration() : nil
        try launchViewer(
            fixture: options.fixture,
            liveConfiguration: liveConfiguration,
            attemptID: nil
        )
    }

    private func prepareProductCatalog() {
        do {
            let migration = try LegacyProfileMigrator().migrateIfNeeded(to: catalogStore)
            if migration == .invalidLegacyProfilePreserved {
                homeErrorText = "旧连接配置无法读取，原数据已保留；请重新配置服务器。"
            }
            catalog = try catalogStore.load()
        } catch {
            catalog = DeviceCatalogDocument()
            catalogMutationBlocked = true
            homeErrorText = "本地设备列表无法读取，原文件已保留。请从服务器设置中确认后重建。"
        }
    }

    private func showHomeUI(error: String = "") {
        activeAttemptID = nil
        if !error.isEmpty { homeErrorText = error }
        player?.stop()
        keyboardController?.disable(message: nil, isError: false, notify: false)
        coreClient?.disconnect()
        liveDecoder?.invalidate()
        memoryTimer?.invalidate()
        hudTimer?.invalidate()
        stopTimer?.invalidate()
        player = nil
        coreClient = nil
        keyboardController = nil
        liveDecoder = nil
        renderer = nil
        metrics = nil
        viewerChrome = nil
        viewerView = nil
        pendingProductConnection?.password = ""
        pendingProductConnection = nil
        let frame = NSRect(x: 0, y: 0, width: 860, height: 680)
        let window = self.window ?? NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RustDesk Native Viewer"
        window.minSize = NSSize(width: 720, height: 560)
        let view = HomeView()
        view.onQuickConnect = { [weak self] peerID in self?.handleQuickConnect(peerID: peerID) }
        view.onOpenServerSettings = { [weak self] in self?.presentServerSettings() }
        view.onDeviceAction = { [weak self] deviceID, action in
            self?.handleDeviceAction(deviceID: deviceID, action: action)
        }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
        homeView = view
        refreshHomeUI()
        if catalog.server == nil, !catalogMutationBlocked {
            DispatchQueue.main.async { [weak self] in self?.presentServerSettings() }
        } else {
            DispatchQueue.main.async { [weak view] in view?.focusQuickConnect() }
        }
    }

    private func refreshHomeUI() {
        guard let homeView else { return }
        var credentialError = false
        let items = catalog.sortedDevices.map { device -> HomeDeviceItem in
            let hasPassword: Bool
            do {
                hasPassword = try credentialStore.contains(deviceID: device.id)
            } catch {
                hasPassword = false
                credentialError = true
            }
            return HomeDeviceItem(device: device, hasSavedPassword: hasPassword)
        }
        var error = homeErrorText
        if credentialError, error.isEmpty {
            error = "部分钥匙串密码暂时无法读取；连接时将要求手动输入。"
        }
        homeView.apply(HomeSnapshot(
            server: catalog.server,
            devices: items,
            statusText: activeAttemptID == nil ? "就绪" : "正在建立安全连接…",
            errorText: error,
            connectingPeerID: pendingProductConnection?.peerID
        ))
    }

    private func handleQuickConnect(peerID: String) {
        guard activeAttemptID == nil else { return }
        guard catalog.server?.isComplete == true else {
            homeErrorText = "请先配置 RustDesk ID 服务器和服务器公钥。"
            refreshHomeUI()
            presentServerSettings()
            return
        }
        if let device = catalog.device(peerID: peerID) {
            connectSavedDevice(device)
        } else {
            promptForPassword(
                deviceID: nil,
                peerID: DeviceCatalogDocument.normalize(peerID),
                saveByDefault: false,
                message: "输入远端设备的访问密码。认证成功后会加入最近连接。"
            )
        }
    }

    private func connectSavedDevice(_ device: SavedDevice) {
        do {
            if let password = try credentialStore.read(deviceID: device.id), !password.isEmpty {
                startProductConnection(
                    deviceID: device.id,
                    deviceExisted: true,
                    peerID: device.peerID,
                    password: password,
                    savePassword: false,
                    usedStoredCredential: true
                )
            } else {
                promptForPassword(
                    deviceID: device.id,
                    peerID: device.peerID,
                    saveByDefault: false,
                    message: "这台设备没有保存密码，请输入本次连接使用的密码。"
                )
            }
        } catch {
            promptForPassword(
                deviceID: device.id,
                peerID: device.peerID,
                saveByDefault: false,
                message: "无法读取已保存密码，请手动输入。"
            )
        }
    }

    private func promptForPassword(
        deviceID: UUID?,
        peerID: String,
        saveByDefault: Bool,
        message: String
    ) {
        guard activeAttemptID == nil, let window else { return }
        let prompt = PasswordPromptController()
        passwordPrompt = prompt
        prompt.begin(
            on: window,
            title: "连接 \(formattedPeerID(peerID))",
            message: message,
            saveByDefault: saveByDefault
        ) { [weak self, weak prompt] result in
            guard let self else { return }
            if self.passwordPrompt === prompt { self.passwordPrompt = nil }
            guard let result else { return }
            self.startProductConnection(
                deviceID: deviceID ?? UUID(),
                deviceExisted: deviceID != nil,
                peerID: peerID,
                password: result.password,
                savePassword: result.saveToKeychain,
                usedStoredCredential: false
            )
        }
    }

    private func startProductConnection(
        deviceID: UUID,
        deviceExisted: Bool,
        peerID: String,
        password: String,
        savePassword: Bool,
        usedStoredCredential: Bool
    ) {
        guard activeAttemptID == nil, let server = catalog.server, server.isComplete else { return }
        let attemptID = UUID()
        activeAttemptID = attemptID
        pendingProductConnection = PendingProductConnection(
            attemptID: attemptID,
            deviceID: deviceID,
            deviceExisted: deviceExisted,
            peerID: peerID,
            password: password,
            savePassword: savePassword,
            usedStoredCredential: usedStoredCredential
        )
        homeErrorText = ""
        refreshHomeUI()

        do {
            let coreURL = URL(fileURLWithPath: defaultCorePath())
            guard FileManager.default.fileExists(atPath: coreURL.path) else {
                throw usageError("bundled Core is unavailable")
            }
            let configuration = CoreConnectionConfig(
                rendezvousServer: server.rendezvousServer,
                serverPublicKey: server.serverPublicKey,
                peerID: peerID,
                password: password,
                forceRelay: server.forceRelay
            )
            try launchViewer(
                fixture: nil,
                liveConfiguration: (coreURL, configuration),
                attemptID: attemptID
            )
        } catch {
            activeAttemptID = nil
            pendingProductConnection?.password = ""
            pendingProductConnection = nil
            showHomeUI(error: sanitizedStartupError(error))
        }
    }

    private func handleAuthenticated(attemptID: UUID) {
        guard activeAttemptID == attemptID,
              var pending = pendingProductConnection,
              pending.attemptID == attemptID else { return }
        var updated = catalog
        let device = updated.recordAuthenticated(
            peerID: pending.peerID,
            preferredID: pending.deviceID
        )
        do {
            if pending.savePassword {
                try credentialStore.upsert(pending.password, deviceID: device.id)
            }
            try catalogStore.save(updated)
            catalog = updated
            homeErrorText = ""
        } catch {
            if pending.savePassword, !pending.deviceExisted {
                try? credentialStore.delete(deviceID: device.id)
            }
            presentNonFatalWarning(
                title: "已连接，但保存失败",
                message: "设备或密码未能安全保存；本次会话仍可继续使用。"
            )
        }
        pending.password = ""
        pendingProductConnection = nil
    }

    private func handleTerminalState(_ event: CoreStateEvent, attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        let retryDeviceID = pendingProductConnection?.deviceID
        let retryDeviceExisted = pendingProductConnection?.deviceExisted ?? false
        let retryPeerID = pendingProductConnection?.peerID
        let retrySaveByDefault = pendingProductConnection.map {
            $0.savePassword || $0.usedStoredCredential
        } ?? false
        let shouldRetryPassword = event.state == .passwordRequired || event.state == .authenticationFailed
        activeAttemptID = nil
        showHomeUI(error: Self.connectionStateText(event))
        guard shouldRetryPassword, let retryDeviceID, let retryPeerID else { return }
        DispatchQueue.main.async { [weak self] in
            self?.promptForPassword(
                deviceID: retryDeviceExisted ? retryDeviceID : nil,
                peerID: retryPeerID,
                saveByDefault: retrySaveByDefault,
                message: "已保存或刚输入的密码不可用，请重新输入。认证成功后才会更新钥匙串。"
            )
        }
    }

    private func handleDeviceAction(deviceID: UUID, action: HomeDeviceAction) {
        guard activeAttemptID == nil, let device = catalog.device(id: deviceID) else { return }
        switch action {
        case .connect:
            connectSavedDevice(device)
        case .toggleFavorite:
            var updated = catalog
            _ = updated.updateDevice(id: deviceID, isFavorite: !device.isFavorite)
            commitCatalog(updated)
        case .rename:
            presentRename(device)
        case .updatePassword:
            promptForPassword(
                deviceID: device.id,
                peerID: device.peerID,
                saveByDefault: true,
                message: "输入新密码并连接。只有认证成功后才会更新钥匙串。"
            )
        case .deletePassword:
            do {
                try credentialStore.delete(deviceID: deviceID)
                homeErrorText = ""
            } catch {
                homeErrorText = "无法删除钥匙串密码，请稍后重试。"
            }
            refreshHomeUI()
        case .deleteDevice:
            presentDeleteConfirmation(device)
        }
    }

    private func presentRename(_ device: SavedDevice) {
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

    private func presentDeleteConfirmation(_ device: SavedDevice) {
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
                self.homeErrorText = ""
            } catch {
                self.homeErrorText = "设备未删除：无法安全清理本地记录或钥匙串密码。"
            }
            self.refreshHomeUI()
        }
    }

    private func presentServerSettings() {
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
        prompt.begin(
            on: window,
            current: catalog.server,
            affectedDevices: catalog.devices.count
        ) { [weak self, weak prompt] configuration in
            guard let self else { return }
            if self.serverPrompt === prompt { self.serverPrompt = nil }
            guard let configuration else { return }
            var updated = self.catalog
            updated.server = configuration
            self.commitCatalog(updated)
            self.homeView?.focusQuickConnect()
        }
    }

    private func commitCatalog(_ updated: DeviceCatalogDocument) {
        guard !catalogMutationBlocked else { return }
        do {
            try catalogStore.save(updated)
            catalog = updated
            homeErrorText = ""
        } catch {
            homeErrorText = "本地设备列表保存失败，请检查磁盘权限后重试。"
        }
        refreshHomeUI()
    }

    private func presentNonFatalWarning(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        alert.beginSheetModal(for: window)
    }

    private func formattedPeerID(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty, compact.allSatisfy(\.isNumber) else { return value }
        return stride(from: 0, to: compact.count, by: 3).map { offset in
            let start = compact.index(compact.startIndex, offsetBy: offset)
            let end = compact.index(start, offsetBy: min(3, compact.count - offset))
            return String(compact[start..<end])
        }.joined(separator: " ")
    }

    private func launchViewer(
        fixture: String?,
        liveConfiguration: (URL, CoreConnectionConfig)?,
        attemptID: UUID?
    ) throws {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let windowFrame = automatedRun && options.fullscreen
            ? screenFrame
            : NSRect(x: 0, y: 0, width: 1280, height: 720)
        let view = ViewerMetalView(frame: windowFrame)
        let provisionalDevice = MetalVideoRenderer.selectDevice(options.gpu)
        guard let deviceName = provisionalDevice?.name else { throw MetalRendererError.noDevice }
        let metrics = PipelineMetrics(
            inputWidth: options.width,
            inputHeight: options.height,
            inputFPS: options.fps,
            selectedGPU: deviceName,
            source: fixture == nil ? "rustdesk-live" : "fixture"
        )
        let renderer = try MetalVideoRenderer(view: view, preference: options.gpu, metrics: metrics)
        let chrome = ViewerChromeView(
            videoView: view,
            metrics: metrics,
            showsAcceptanceControls: automatedRun && fixture == nil
        )
        let window = self.window ?? NSWindow(
            contentRect: windowFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fixture == nil ? "RustDesk Native Viewer" : "RustDesk Native Viewer — Fixture"
        window.minSize = NSSize(width: 720, height: 480)
        window.contentView = chrome
        if !options.fullscreen || !automatedRun { window.setContentSize(windowFrame.size); window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
        self.renderer = renderer
        self.metrics = metrics
        viewerView = view
        viewerChrome = chrome
        homeView = nil
        startedAt = Date()

        let sendKey: (CoreKeyEvent) -> Int32 = { [weak self] event in
            self?.coreClient?.sendKey(event) ?? -3
        }
        let recordInputResult: (String, Int32) -> Void = { [weak chrome, weak metrics] category, status in
            if status == 0 {
                metrics?.recordInput(category: category, accepted: true)
            } else if status == -6 {
                metrics?.recordInput(category: category, accepted: false)
            }
            if status == -6 {
                DispatchQueue.main.async {
                    chrome?.updateState("远端尚未授予键盘与鼠标控制权限", isError: true)
                }
            }
        }
        view.sendPointer = { [weak self] event in self?.coreClient?.sendPointer(event) ?? -3 }
        view.sendKey = sendKey
        view.sendText = { [weak self] text in self?.coreClient?.sendText(text) ?? -3 }
        view.recordInputResult = recordInputResult
        if liveConfiguration != nil {
            let keyboardController = ExclusiveKeyboardController(
                sendKey: sendKey,
                recordInputResult: recordInputResult
            )
            keyboardController.onStatusChange = { [weak chrome, weak view] active, message, isError, didActivate in
                view?.setKeyboardInputEnabled(!active)
                chrome?.updateKeyboardGrab(active: active, message: message, isError: isError)
                if didActivate { metrics.recordExclusiveKeyboardActivation() }
                if isError { metrics.recordExclusiveKeyboardFailure() }
            }
            chrome.onToggleKeyboardGrab = { [weak keyboardController] in keyboardController?.toggle() }
            chrome.onOpenKeyboardPermissions = { Self.openKeyboardPrivacySettings() }
            chrome.onControlOverlayVisibilityChanged = { [weak keyboardController] expanded in
                if expanded {
                    keyboardController?.suspend(message: "本地控制菜单已打开，键盘独占已暂时释放")
                } else {
                    keyboardController?.resumeIfRequested()
                }
            }
            view.onWindowResignKey = { [weak keyboardController] in
                keyboardController?.suspend(
                    message: "窗口失去焦点，已暂时释放键盘；返回后自动恢复独占"
                )
            }
            view.onWindowBecomeKey = { [weak keyboardController] in
                keyboardController?.resumeIfRequested()
            }
            self.keyboardController = keyboardController
        } else {
            keyboardController = nil
        }
        chrome.onToggleFullscreen = { [weak window] in window?.toggleFullScreen(nil) }
        chrome.onDisconnect = { [weak self] in
            guard let self else { return }
            if self.automatedRun { NSApplication.shared.terminate(nil) }
            else { self.showHomeUI() }
        }

        if let fixture {
            try startFixture(fixture, renderer: renderer, metrics: metrics)
        } else if let liveConfiguration {
            try startLive(
                coreURL: liveConfiguration.0,
                configuration: liveConfiguration.1,
                renderer: renderer,
                metrics: metrics,
                viewer: view,
                chrome: chrome,
                attemptID: attemptID
            )
        }

        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak metrics] _ in metrics?.sampleMemory() }
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak chrome, weak metrics] _ in
            if let value = metrics?.hudSnapshot() { chrome?.updateHUD(value) }
        }
        if automatedRun {
            stopTimer = Timer.scheduledTimer(withTimeInterval: options.duration, repeats: false) { _ in
                NSApplication.shared.terminate(nil)
            }
        }
        if automatedRun, options.fullscreen {
            DispatchQueue.main.async { [weak window] in window?.toggleFullScreen(nil) }
        }
        print("PIPELINE_STARTED source=\(fixture == nil ? "rustdesk-live" : "fixture") gpu=\(renderer.deviceName) fullscreen=\(options.fullscreen) duration=\(automatedRun ? options.duration : 0)")
    }

    private func startFixture(
        _ fixture: String,
        renderer: MetalVideoRenderer,
        metrics: PipelineMetrics
    ) throws {
        guard options.width > 0, options.height > 0 else { throw usageError("--width and --height are required for fixture mode") }
        let fixtureURL = URL(fileURLWithPath: fixture)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else { throw usageError("fixture not found: \(fixture)") }
        let player = try FixturePlayer(
            fixtureURL: fixtureURL,
            fps: options.fps,
            metrics: metrics,
            output: { [weak renderer] pixelBuffer, _ in renderer?.enqueue(pixelBuffer) }
        )
        self.player = player
        player.start()
    }

    private func startLive(
        coreURL: URL,
        configuration: CoreConnectionConfig,
        renderer: MetalVideoRenderer,
        metrics: PipelineMetrics,
        viewer: ViewerMetalView,
        chrome: ViewerChromeView,
        attemptID: UUID?
    ) throws {
        guard FileManager.default.fileExists(atPath: coreURL.path) else { throw usageError("core library not found: \(coreURL.path)") }

        let decoder = LiveHEVCDecoder(
            metrics: metrics,
            output: { [weak renderer] pixelBuffer, _ in renderer?.enqueue(pixelBuffer) }
        )
        let recovery = CoreRecoveryCoordinator()
        let fallbackFPS = options.fps
        let keyboardController = self.keyboardController
        let client = try RustDeskCoreClient(
            libraryURL: coreURL,
            onState: { [weak self, weak chrome, weak keyboardController] event in
                let value = "\(event.state):\(event.code)"
                metrics.recordCoreState(value)
                print("CORE_STATE state=\(event.state) code=\(event.code)")
                let chrome = chrome
                let keyboardController = keyboardController
                let appDelegate = self
                DispatchQueue.main.async {
                    if let attemptID, appDelegate?.activeAttemptID != attemptID { return }
                    chrome?.updateState(Self.connectionStateText(event), isError: Self.isErrorState(event.state))
                    if event.state == .authenticated, let attemptID {
                        appDelegate?.handleAuthenticated(attemptID: attemptID)
                    }
                    if event.state == .controlReady {
                        chrome?.setKeyboardGrabAvailable(true)
                    } else if event.state == .passwordRequired || event.state == .authenticationFailed ||
                                event.state == .error || event.state == .disconnected {
                        chrome?.setKeyboardGrabAvailable(false)
                        keyboardController?.disable(
                            message: "连接状态变化，已退出键盘独占",
                            isError: false
                        )
                    }
                    if Self.isTerminalState(event.state), appDelegate?.automatedRun != true,
                       appDelegate?.viewerChrome != nil, let attemptID {
                        appDelegate?.handleTerminalState(event, attemptID: attemptID)
                    }
                }
                if Self.isTerminalState(event.state) {
                    if self?.automatedRun == true {
                        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                    }
                }
            },
            onVideo: { [weak viewer] packet in
                if packet.width > 0, packet.height > 0 {
                    let viewer = viewer
                    DispatchQueue.main.async {
                        viewer?.updateRemoteSize(width: Int(packet.width), height: Int(packet.height))
                    }
                }
                Self.consume(
                    packet: packet,
                    decoder: decoder,
                    metrics: metrics,
                    fallbackFPS: fallbackFPS,
                    recovery: recovery
                )
            },
            onMetrics: { value in
                metrics.recordCoreMetrics(
                    remoteFPS: value.remoteFPS,
                    networkDelayMS: Int(value.networkDelayMS),
                    targetBitrate: value.targetBitrate
                )
            }
        )
        recovery.attach(client)
        try client.connect(configuration)
        liveDecoder = decoder
        coreClient = client
        print("CORE_LOADED abi=\(RustDeskCoreClient.abiVersion) upstream=\(client.upstreamCommit) password_source=environment-or-interactive")
    }

    private func environmentConnectionConfiguration() throws -> (URL, CoreConnectionConfig) {
        guard let coreLibrary = options.coreLibrary, !coreLibrary.isEmpty else {
            throw usageError("--core is required for live mode")
        }
        let server = takeEnvironment(options.serverEnvironment)
        let key = takeEnvironment(options.keyEnvironment)
        let peerID = takeEnvironment(options.peerIDEnvironment)
        let password = takeEnvironment(options.passwordEnvironment)
        guard !server.isEmpty, !key.isEmpty, !peerID.isEmpty else {
            throw usageError("live connection environment is incomplete")
        }
        return (
            URL(fileURLWithPath: coreLibrary),
            CoreConnectionConfig(
                rendezvousServer: server,
                serverPublicKey: key,
                peerID: peerID,
                password: password,
                forceRelay: options.forceRelay
            )
        )
    }

    private func takeEnvironment(_ name: String) -> String {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        unsetenv(name)
        return value
    }

    private func defaultCorePath() -> String {
        if let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("liblibrustdesk.dylib"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        #if arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "arm64"
        #endif
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("CoreBridge/\(architecture)/liblibrustdesk.dylib")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling.path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Build/CoreBridge/\(architecture)/liblibrustdesk.dylib").path
    }

    private func sanitizedStartupError(_ error: Error) -> String {
        switch error {
        case CoreBridgeError.load(_):
            return "无法加载兼容的 RustDesk Core，请检查动态库与 ABI。"
        case CoreBridgeError.createClient:
            return "无法创建连接会话。"
        case CoreBridgeError.connect(_):
            return "连接启动失败，请检查配置后重试。"
        case CoreBridgeError.invalidUpstreamCommit(_):
            return "RustDesk Core 版本不匹配。"
        default:
            return "连接配置无效或本地组件不可用。"
        }
    }

    private static func openKeyboardPrivacySettings() {
        let alert = NSAlert()
        alert.messageText = "允许独占键盘"
        alert.informativeText = "独占键盘需要“辅助功能”和“输入监控”两项权限。授权后无需保存密码；使用 ⌃⌥⇧Esc 可随时退出独占。"
        alert.addButton(withTitle: "打开辅助功能")
        alert.addButton(withTitle: "打开输入监控")
        alert.addButton(withTitle: "取消")
        let destination: String
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            destination = "Privacy_Accessibility"
        case .alertSecondButtonReturn:
            destination = "Privacy_ListenEvent"
        default:
            return
        }
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(destination)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func isErrorState(_ state: CoreConnectionState) -> Bool {
        state == .passwordRequired || state == .authenticationFailed || state == .error || state == .disconnected
    }

    private static func isTerminalState(_ state: CoreConnectionState) -> Bool {
        state == .passwordRequired || state == .authenticationFailed ||
            state == .error || state == .disconnected
    }

    private static func connectionStateText(_ event: CoreStateEvent) -> String {
        switch event.state {
        case .idle: return "等待连接"
        case .connecting: return "正在连接…"
        case .transportReady: return "安全传输已建立"
        case .authenticated: return "认证成功"
        case .streaming: return "实时画面"
        case .controlReady: return "远端控制已授权"
        case .passwordRequired: return "需要密码，请重新连接"
        case .authenticationFailed: return "认证失败，请检查密码"
        case .disconnected: return "连接已断开"
        case .error: return "连接发生错误，请检查网络与远端状态"
        }
    }

    private static func consume(
        packet: CoreVideoPacket,
        decoder: LiveHEVCDecoder,
        metrics: PipelineMetrics,
        fallbackFPS: Double,
        recovery: CoreRecoveryCoordinator
    ) {
        let codec = packet.codec == .h265 ? "h265" : packet.codec == .h264 ? "h264" : "unknown"
        let declaredFormat: HEVCPacketFormat?
        let format: String
        switch packet.format {
        case .annexB: declaredFormat = .annexB; format = "annex-b"
        case .avcc: declaredFormat = .avcc; format = "avcc"
        case .mixed: declaredFormat = nil; format = "mixed"
        case .unknown: declaredFormat = nil; format = "unknown"
        }
        metrics.recordEncodedPacket(
            codec: codec,
            format: format,
            byteCount: packet.data.count,
            sequence: packet.sequence,
            timestampUS: packet.timestampUS,
            isKeyframe: packet.isKeyframe,
            containsVPS: packet.containsVPS,
            containsSPS: packet.containsSPS,
            containsPPS: packet.containsPPS,
            width: Int(packet.width),
            height: Int(packet.height)
        )
        guard packet.codec == .h265, let declaredFormat else {
            metrics.recordDecodeError()
            return
        }
        do {
            let encoded = try HEVCEncodedPacket(data: packet.data, declaredFormat: declaredFormat)
            let sets = encoded.parameterSets
            guard encoded.isKeyframe == packet.isKeyframe,
                  (sets[32] != nil) == packet.containsVPS,
                  (sets[33] != nil) == packet.containsSPS,
                  (sets[34] != nil) == packet.containsPPS else {
                metrics.recordDecodeError()
                return
            }
            try decoder.submit(
                encoded,
                sequence: Int64(clamping: packet.sequence),
                timestampUS: packet.timestampUS,
                fps: max(1, fallbackFPS)
            )
        } catch let error as LiveHEVCDecoderError {
            switch error {
            case .waitingForParameterSets, .waitingForKeyframe:
                // Parameter sets and an IDR may legitimately arrive after transport setup.
                break
            case .referenceFrameDropped:
                requestRecoveryKeyframe(
                    display: packet.display,
                    reason: "reference-frame-drop",
                    metrics: metrics,
                    recovery: recovery
                )
            case .asynchronousDecodeFailure(let status):
                requestRecoveryKeyframe(
                    display: packet.display,
                    reason: "decode-status-\(status)",
                    metrics: metrics,
                    recovery: recovery
                )
            }
        } catch {
            metrics.recordDecodeError()
            fputs("live decode submit error: \(error)\n", stderr)
        }
    }

    private static func requestRecoveryKeyframe(
        display: UInt32,
        reason: String,
        metrics: PipelineMetrics,
        recovery: CoreRecoveryCoordinator
    ) {
        let requested = recovery.requestKeyframe(display: display)
        if requested { metrics.recordKeyframeRequest() }
        fputs("live decoder reset reason=\(reason) keyframe-requested=\(requested)\n", stderr)
    }

    private func usageError(_ message: String) -> NSError {
        NSError(domain: "RustDeskNative", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func finish() {
        guard !didFinish, let metrics else { return }
        didFinish = true
        player?.stop()
        keyboardController?.disable(message: nil, isError: false, notify: false)
        viewerView?.releaseAllInput()
        coreClient?.disconnect()
        liveDecoder?.invalidate()
        memoryTimer?.invalidate()
        hudTimer?.invalidate()
        stopTimer?.invalidate()
        let report = metrics.snapshot(durationOverride: Date().timeIntervalSince(startedAt))
        do {
            let data = try JSONEncoder.pretty.encode(report)
            let url = URL(fileURLWithPath: options.output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            print("BENCHMARK_WRITTEN \(url.path)")
        } catch {
            fputs("failed to write benchmark: \(error)\n", stderr)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
