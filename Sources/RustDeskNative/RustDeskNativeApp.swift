import AppKit
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

@main
private final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let options = Options(arguments: CommandLine.arguments)
    private let profileStore = ViewerConnectionProfileStore()
    private var window: NSWindow?
    private var connectionView: ConnectionView?
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
            showConnectionUI()
            return
        }
        automatedRun = true
        let liveConfiguration = options.fixture == nil ? try environmentConnectionConfiguration() : nil
        try launchViewer(fixture: options.fixture, liveConfiguration: liveConfiguration)
    }

    private func showConnectionUI(error: String = "") {
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
        let frame = NSRect(x: 0, y: 0, width: 780, height: 680)
        let window = self.window ?? NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RustDesk Native Viewer"
        window.minSize = NSSize(width: 700, height: 600)
        let view = ConnectionView(savedProfile: profileStore.load())
        view.onClearSavedProfile = { [weak self] in self?.profileStore.clear() }
        view.onConnect = { [weak self] draft in
            guard let self else { return }
            do {
                let coreURL = URL(fileURLWithPath: self.defaultCorePath())
                guard FileManager.default.fileExists(atPath: coreURL.path) else {
                    throw self.usageError("bundled Core is unavailable")
                }
                if draft.rememberProfile { self.profileStore.save(draft.profile) }
                else { self.profileStore.clear() }
                let configuration = CoreConnectionConfig(
                    rendezvousServer: draft.rendezvousServer,
                    serverPublicKey: draft.serverPublicKey,
                    peerID: draft.peerID,
                    password: draft.password,
                    forceRelay: draft.forceRelay
                )
                try self.launchViewer(fixture: nil, liveConfiguration: (coreURL, configuration))
            } catch {
                self.showConnectionUI(error: self.sanitizedStartupError(error))
            }
        }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        view.showError(error)
        self.window = window
        connectionView = view
    }

    private func launchViewer(
        fixture: String?,
        liveConfiguration: (URL, CoreConnectionConfig)?
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
        connectionView = nil
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
            else { self.showConnectionUI() }
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
                chrome: chrome
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
        chrome: ViewerChromeView
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
                let value = "\(event.state):\(event.code):\(event.message)"
                metrics.recordCoreState(value)
                print("CORE_STATE state=\(event.state) code=\(event.code) message=\(event.message)")
                let chrome = chrome
                let keyboardController = keyboardController
                let appDelegate = self
                DispatchQueue.main.async {
                    chrome?.updateState(Self.connectionStateText(event), isError: Self.isErrorState(event.state))
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
                       appDelegate?.viewerChrome != nil {
                        appDelegate?.showConnectionUI(error: Self.connectionStateText(event))
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
