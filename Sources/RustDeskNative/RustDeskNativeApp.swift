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

/// Breaks the construction cycle between the pipeline and its access-unit
/// callback while keeping backpressure recovery on the encoder callback
/// boundary. A late callback can only reach its own (possibly cancelled)
/// pipeline, never the next route stored by AppDelegate.
private final class HostMediaPipelineReference: @unchecked Sendable {
    private let lock = NSLock()
    private weak var pipeline: HostMediaPipeline?

    func bind(_ pipeline: HostMediaPipeline) {
        lock.lock()
        self.pipeline = pipeline
        lock.unlock()
    }

    func recoverFromEncodedPacketDrop() {
        lock.lock()
        let pipeline = pipeline
        lock.unlock()
        pipeline?.recoverFromEncodedPacketDrop()
    }
}

private extension HostMediaSubmissionDropReason {
    var telemetryReason: HostMediaDropReason {
        switch self {
        case .networkBackpressure: return .networkBackpressure
        case .reconfigure: return .reconfigure
        case .invalidFrame: return .invalidFrame
        case .shutdown: return .shutdown
        }
    }
}

@main
private final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private static let hostEnabledDefaultsKey = "farpane.host.enabled"

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
    private var hostSessionStatusItem: NSStatusItem?
    private var hostSessionIndicatorPresentation: HostSessionIndicatorPresentation?
    private var passwordPrompt: PasswordPromptController?
    private var hostPermanentPasswordPrompt: HostPermanentPasswordPromptController?
    private var serverPrompt: ServerSettingsPromptController?
    private var viewerChrome: ViewerChromeView?
    private var viewerView: ViewerMetalView?
    private var renderer: MetalVideoRenderer?
    private var player: FixturePlayer?
    private var liveDecoder: LiveHEVCDecoder?
    private var coreClient: RustDeskCoreClient?
    private var hostClient: HostControlClient?
    private var hostRuntimeActive = false
    private var hostMediaPipeline: HostMediaPipeline?
    private var hostMediaEvidenceWriter: HostMediaTelemetryEvidenceWriter?
    private var hostMediaLiveLogWriter: HostMediaTelemetryLiveLogWriter?
    private var hostRuntimeStateEvidenceWriter: HostRuntimeStateEvidenceWriter?
    private var hostMediaRoute: HostMediaControl?
    private var hostMediaSuspendedForSessionUnavailable = false
    private var hostMediaStatusText: String?
    private var hostMediaGeneration: UInt64 = 0
    private var hostMediaCapabilitiesInstanceID = ""
    private var hostMediaCapabilitiesProbeID: UUID?
    private var hostMediaCapabilitiesProbeTask: Task<Void, Never>?
    private var hostSnapshot: HostCoreSnapshot?
    private var hostApprovalDecisionGate = HostApprovalDecisionGate()
    private var hostSessionCommandGate = HostSessionCommandGate()
    private var hostTemporaryPassword = ""
    private var hostStatusText = "已关闭"
    private var hostErrorText = ""
    private var hostPollTimer: Timer?
    private var hostPasswordHideTimer: Timer?
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
            hostRuntimeStateEvidenceWriter = try HostRuntimeStateEvidenceWriter.configured()
        } catch {
            hostRuntimeStateEvidenceWriter = nil
            fputs("Host runtime-state evidence output is invalid or already exists.\n", stderr)
        }
        recordHostRuntimeStateEvidence(force: true)
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
        HostApplicationLifecyclePolicy.shouldTerminateAfterLastWindowClosed(
            hostRuntimeActive: hostRuntimeActive
        )
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            bringMainWindowForward()
        }
        return true
    }

    private func bringMainWindowForward() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
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
        window.title = "FarPane"
        window.minSize = NSSize(width: 720, height: 560)
        let view = HomeView()
        view.onQuickConnect = { [weak self] peerID in self?.handleQuickConnect(peerID: peerID) }
        view.onOpenServerSettings = { [weak self] in self?.presentServerSettings() }
        view.onDeviceAction = { [weak self] deviceID, action in
            self?.handleDeviceAction(deviceID: deviceID, action: action)
        }
        view.onHostToggle = { [weak self] enabled in self?.setHostModeEnabled(enabled) }
        view.onRevealHostPassword = { [weak self] in self?.revealHostTemporaryPassword() }
        view.onRegenerateHostPassword = { [weak self] in self?.regenerateHostTemporaryPassword() }
        view.onSetHostPermanentPassword = { [weak self] in self?.presentHostPermanentPassword() }
        view.onClearHostPermanentPassword = { [weak self] in self?.confirmClearHostPermanentPassword() }
        view.onApproveHostConnection = { [weak self] connectionID in
            self?.resolveHostApproval(connectionID: connectionID, decision: .approve)
        }
        view.onRejectHostConnection = { [weak self] connectionID in
            self?.resolveHostApproval(connectionID: connectionID, decision: .reject)
        }
        view.onHostSessionAction = { [weak self] connectionID, action in
            self?.performHostSessionAction(connectionID: connectionID, action: action)
        }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
        homeView = view
        if UserDefaults.standard.bool(forKey: Self.hostEnabledDefaultsKey), !hostRuntimeActive {
            startHostMode()
        }
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
            connectingPeerID: pendingProductConnection?.peerID,
            host: HostHomeSnapshot(
                isEnabled: UserDefaults.standard.bool(forKey: Self.hostEnabledDefaultsKey),
                isRunning: hostRuntimeActive,
                isStreaming: hostMediaRoute != nil,
                statusText: hostStatusText,
                localID: hostSnapshot?.localId ?? "",
                temporaryPassword: hostTemporaryPassword,
                localPermanentPasswordSet: hostSnapshot?.passwordPolicy.localPasswordSet ?? false,
                effectivePermanentPasswordSet: hostSnapshot?.passwordPolicy.effectivePasswordSet ?? false,
                usingPresetPassword: hostSnapshot?.passwordPolicy.usingPresetPassword ?? false,
                permanentPasswordChangeAllowed: hostSnapshot?.passwordPolicy.changeAllowed ?? false,
                pendingApproval: hostApprovalHomeSnapshot(),
                activeSession: hostActiveSessionHomeSnapshot(),
                mediaDiagnosticText: hostMediaDiagnosticText(),
                errorText: hostErrorText
            )
        ))
    }

    private func hostMediaDiagnosticText() -> String {
        guard let snapshot = hostMediaPipeline?.telemetry.snapshot() else { return "" }
        let averageFPS = snapshot.validFrames > 1
            ? String(format: "%.1f", snapshot.actualFPS)
            : "—"
        let recentFPS = snapshot.validFrames > 1
            ? String(format: "%.1f", snapshot.recentCaptureFPS)
            : "—"
        let recentEncodedFPS = snapshot.encodedPackets > 1
            ? String(format: "%.1f", snapshot.recentEncodedFPS)
            : "—"
        let recentSendAcceptedFPS = snapshot.sendAccepted > 1
            ? String(format: "%.1f", snapshot.recentSendAcceptedFPS)
            : "—"
        let contentState: String
        switch snapshot.captureContentState {
        case .idle: contentState = "静止"
        case .lowMotion: contentState = "低活动"
        case .interactive: contentState = "交互"
        case .highMotion: contentState = "高活动"
        }
        let pressure: String
        switch snapshot.capturePressureLevel {
        case .none: pressure = "无"
        case .moderate: pressure = "中"
        case .severe: pressure = "高"
        }
        let pressureDetail = hostPressureDiagnosticText(snapshot)
        let updateState = snapshot.captureConfigurationUpdateInFlight ? " · 调档中" : ""
        let cadence = "\(snapshot.captureTargetFPS)/\(snapshot.captureAppliedFPS)"
        return "近5秒 采集/编码/入Rust \(recentFPS)/\(recentEncodedFPS)"
            + "/\(recentSendAcceptedFPS) FPS · 采集均值 \(averageFPS)"
            + "\n目标/已应用 \(cadence) · \(contentState) · 压力 \(pressure)"
            + "\(pressureDetail)\(updateState)"
    }

    private func hostPressureDiagnosticText(_ snapshot: HostMediaTelemetrySnapshot) -> String {
        let observed: String
        switch snapshot.captureObservedPressureLevel {
        case .none: observed = "无"
        case .moderate: observed = "中"
        case .severe: observed = "高"
        }
        let causes = snapshot.capturePressureCauses.map { cause -> String in
            switch cause {
            case .thermalState:
                return "热状态 \(snapshot.thermalState ?? "未知")"
            case .lowPowerMode:
                return "低电量模式"
            case .encodeInFlight:
                return "编码在途 \(snapshot.encodeInFlight)"
            case .encodeLatency:
                return String(
                    format: "编码延迟 %.1fms",
                    snapshot.latestEncodeLatencyMS ?? 0
                )
            case .consecutiveSendDrops:
                return "连续入Rust失败 \(snapshot.consecutiveSendDrops)"
            case .recentSendDropRate:
                return String(
                    format: "入Rust丢弃 %.0f%%/%d",
                    snapshot.recentSendDropRate * 100,
                    snapshot.recentSendOutcomeCount
                )
            case .encodedQueue:
                return "Rust队列 \(snapshot.encodedQueueDepth ?? 0)"
                    + "/\(snapshot.encodedQueueCapacity ?? 0)"
            case .networkDelay:
                return "网络延迟 \(snapshot.networkDelayMS ?? 0)ms"
            case .roundTripTime:
                return "RTT \(snapshot.roundTripTimeMS ?? 0)ms"
            case .responseDelayed:
                return "响应延迟订阅 \(snapshot.responseDelayedSubscribers)"
            }
        }
        if causes.isEmpty {
            return snapshot.captureObservedPressureLevel == snapshot.capturePressureLevel
                ? ""
                : "（当前 \(observed)，滞回恢复中）"
        }
        let prefix = snapshot.captureObservedPressureLevel == snapshot.capturePressureLevel
            ? ""
            : "当前 \(observed)："
        return "（\(prefix)\(causes.joined(separator: "，"))）"
    }

    private func setHostModeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.hostEnabledDefaultsKey)
        if enabled {
            startHostMode()
        } else {
            stopHostMode(preservePreference: false, reason: .userRequest)
        }
        refreshHomeUI()
    }

    private func startHostMode() {
        guard !hostRuntimeActive else { return }
        guard coreClient == nil else {
            hostStatusText = "远程控制期间已暂停"
            hostErrorText = ""
            return
        }
        guard let server = catalog.server, server.isComplete else {
            hostStatusText = "需要服务器配置"
            hostErrorText = "请先配置 RustDesk ID 服务器和服务器公钥。"
            return
        }

        hostStatusText = "正在连接服务器…"
        hostMediaStatusText = nil
        hostErrorText = ""
        hostSnapshot = nil
        hostApprovalDecisionGate.reset()
        hostSessionCommandGate.reset()
        removeHostSessionStatusItem()
        hostTemporaryPassword = ""
        do {
            let coreURL = URL(fileURLWithPath: defaultCorePath())
            guard FileManager.default.fileExists(atPath: coreURL.path) else {
                throw HostControlError.load("core unavailable")
            }
            let client: HostControlClient
            if let existing = hostClient {
                client = existing
            } else {
                let created = try HostControlClient(
                    libraryURL: coreURL,
                    eventQueue: .main
                ) { [weak self] event in
                    self?.handleHostCoreEvent(event)
                }
                try created.setConfigRoot(appName: "FarPaneHost", org: "io.rustdesknative")
                hostClient = created
                client = created
            }
            try client.start(configuration: HostServerConfiguration(
                rendezvousServer: server.rendezvousServer,
                serverPublicKey: server.serverPublicKey
            ))
            hostRuntimeActive = true
            refreshHostSnapshot()
            hostPollTimer?.invalidate()
            hostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refreshHostSnapshot()
            }
        } catch {
            hostRuntimeActive = false
            hostSnapshot = nil
            hostStatusText = "启动失败"
            hostErrorText = sanitizedHostError(error)
            recordHostRuntimeStateEvidence(force: true)
        }
    }

    private func stopHostMode(
        preservePreference: Bool,
        reason: HostStopReason,
        releaseClient: Bool = false
    ) {
        hostPollTimer?.invalidate()
        hostPollTimer = nil
        hostPasswordHideTimer?.invalidate()
        hostPasswordHideTimer = nil
        hostTemporaryPassword = ""
        hostSnapshot = nil
        hostApprovalDecisionGate.reset()
        hostSessionCommandGate.reset()
        removeHostSessionStatusItem()
        stopHostMediaPipeline()
        hostMediaCapabilitiesProbeTask?.cancel()
        hostMediaCapabilitiesProbeTask = nil
        hostMediaCapabilitiesProbeID = nil
        hostMediaCapabilitiesInstanceID = ""
        if !preservePreference {
            UserDefaults.standard.set(false, forKey: Self.hostEnabledDefaultsKey)
        }
        do {
            if hostRuntimeActive {
                try hostClient?.stop(reason: reason)
            }
            hostErrorText = ""
        } catch {
            hostErrorText = sanitizedHostError(error)
        }
        hostRuntimeActive = false
        if releaseClient { hostClient = nil }
        hostStatusText = preservePreference ? "远程控制期间已暂停" : "已关闭"
        recordHostRuntimeStateEvidence(force: true)
    }

    @discardableResult
    private func refreshHostSnapshot() -> Bool {
        guard hostRuntimeActive, let hostClient else { return false }
        var refreshed = false
        do {
            let snapshot = try hostClient.copySnapshot()
            hostSnapshot = snapshot
            refreshed = true
            syncHostMediaCaptureAvailability(activeSession: snapshot.activeSession)
            hostSessionCommandGate.observe(
                connectionID: snapshot.activeSession?.connectionId,
                activeCapabilities: snapshot.activeSession?.activeCapabilities ?? []
            )
            syncHostSessionStatusItem()
            let shouldRequestAttention = hostApprovalDecisionGate.observe(
                connectionID: snapshot.pendingApproval?.connectionId
            )
            configureHostMediaCapabilitiesIfNeeded(snapshot: snapshot, client: hostClient)
            if let pending = snapshot.pendingApproval {
                hostStatusText = hostApprovalDecisionGate.isResolving(
                    connectionID: pending.connectionId
                ) ? "正在处理连接请求…" : "等待本机批准…"
            } else if let session = snapshot.activeSession,
                      let inputPresentation = HostSessionInputPresentationPolicy.presentation(
                          availability: session.inputAvailability,
                          unavailableReason: session.inputUnavailableReason
                      ) {
                hostStatusText = session.inputAvailability == .limited
                    ? inputPresentation.overallStatusText
                    : (hostMediaStatusText ?? inputPresentation.overallStatusText)
            } else {
                switch snapshot.registrationStatus {
                case "ready": hostStatusText = hostMediaStatusText ?? "可被连接"
                case "degraded": hostStatusText = "连接异常"
                default: hostStatusText = "正在连接服务器…"
                }
            }
            hostErrorText = snapshot.lastError == nil ? "" : "Host 服务暂时不可用，将继续重试。"
            if shouldRequestAttention {
                requestAttentionForPendingHostApproval()
            }
        } catch {
            suspendHostMediaPipelineForSessionUnavailable()
            removeHostSessionStatusItem()
            hostStatusText = "状态不可用"
            hostErrorText = sanitizedHostError(error)
        }
        recordHostRuntimeStateEvidence()
        recordHostMediaLiveLog()
        refreshHomeUI()
        return refreshed
    }

    private func hostApprovalHomeSnapshot() -> HostApprovalHomeSnapshot? {
        guard let pending = hostSnapshot?.pendingApproval else { return nil }
        let capabilityNames = pending.requestedCapabilities.compactMap { capability -> String? in
            switch capability {
            case "viewDisplay": return "查看屏幕"
            case "controlKeyboardMouse": return "控制键盘与鼠标"
            case "readClipboard": return "读取剪贴板"
            case "writeClipboard": return "写入剪贴板"
            case "hearSystemAudio": return "收听系统音频"
            default: return nil
            }
        }
        guard capabilityNames.count == pending.requestedCapabilities.count else { return nil }

        let claimedName = pending.remoteName.isEmpty ? pending.remoteId : pending.remoteName
        let identityText = pending.remoteName.isEmpty
            ? "对方声明（未经验证）：\(claimedName)"
            : "对方声明（未经验证）：\(claimedName) · ID \(pending.remoteId)"
        let platformText = pending.remotePlatform.isEmpty ? "未知平台" : pending.remotePlatform
        let transportText: String
        switch pending.transport {
        case "direct": transportText = "直连"
        case "relay": transportText = "中继"
        case "unknown": transportText = "连接方式尚未确认"
        default: return nil
        }
        let nowMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        let remainingMilliseconds = pending.expiresAt > nowMilliseconds
            ? pending.expiresAt - nowMilliseconds
            : 0
        let remainingSeconds = remainingMilliseconds / 1_000
            + (remainingMilliseconds.isMultiple(of: 1_000) ? 0 : 1)
        let expiryText = remainingSeconds == 0
            ? "正在自动拒绝已超时请求"
            : "约 \(remainingSeconds) 秒后自动拒绝"

        return HostApprovalHomeSnapshot(
            connectionID: pending.connectionId,
            remoteIdentityText: identityText,
            contextText: "\(platformText) · \(transportText) · 每次均需本机批准",
            capabilityText: "请求权限：\(capabilityNames.joined(separator: "、"))",
            expiryText: expiryText,
            isResolving: hostApprovalDecisionGate.isResolving(
                connectionID: pending.connectionId
            )
        )
    }

    private func hostActiveSessionHomeSnapshot() -> HostActiveSessionHomeSnapshot? {
        guard let session = hostSnapshot?.activeSession else { return nil }
        let activeCapabilities = Set(session.activeCapabilities)
        let capabilityNames = session.activeCapabilities.compactMap { capability -> String? in
            switch capability {
            case "viewDisplay": return "查看屏幕"
            case "controlKeyboardMouse": return "控制键盘与鼠标"
            case "readClipboard": return "读取剪贴板"
            case "writeClipboard": return "写入剪贴板"
            case "hearSystemAudio": return "收听系统音频"
            default: return nil
            }
        }
        guard capabilityNames.count == session.activeCapabilities.count else { return nil }

        let claimedName = session.remoteName.isEmpty ? session.remoteId : session.remoteName
        let identityText = session.remoteName.isEmpty
            ? "对方声明（未经验证）：\(claimedName)"
            : "对方声明（未经验证）：\(claimedName) · ID \(session.remoteId)"
        let platformText = session.remotePlatform.isEmpty ? "未知平台" : session.remotePlatform
        let startedAt = Date(timeIntervalSince1970: TimeInterval(session.startedAt) / 1_000)
        let startedText = DateFormatter.localizedString(
            from: startedAt,
            dateStyle: .none,
            timeStyle: .short
        )
        let pendingAction: HostSessionHomeAction?
        switch hostSessionCommandGate.resolvingIntent(connectionID: session.connectionId) {
        case .disable(.keyboardAndMouse): pendingAction = .disableKeyboardAndMouse
        case .disable(.clipboard): pendingAction = .disableClipboard
        case .disable(.systemAudio): pendingAction = .disableSystemAudio
        case .disconnect: pendingAction = .disconnect
        case nil: pendingAction = nil
        }
        guard let inputPresentation = HostSessionInputPresentationPolicy.presentation(
            availability: session.inputAvailability,
            unavailableReason: session.inputUnavailableReason
        ) else { return nil }
        let capabilityText = [
            "当前权限：\(capabilityNames.joined(separator: "、"))",
            inputPresentation.detailText,
        ].compactMap { $0 }.joined(separator: "；")

        return HostActiveSessionHomeSnapshot(
            connectionID: session.connectionId,
            remoteIdentityText: identityText,
            contextText: "\(platformText) · \(startedText) 开始连接",
            capabilityText: capabilityText,
            canDisableKeyboardAndMouse: activeCapabilities.contains("controlKeyboardMouse"),
            canDisableClipboard: activeCapabilities.contains("readClipboard")
                && activeCapabilities.contains("writeClipboard"),
            canDisableSystemAudio: activeCapabilities.contains("hearSystemAudio"),
            pendingAction: pendingAction
        )
    }

    private func requestAttentionForPendingHostApproval() {
        NSApplication.shared.requestUserAttention(.criticalRequest)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func resolveHostApproval(
        connectionID: String,
        decision: HostApprovalDecision
    ) {
        guard hostRuntimeActive,
              let hostClient,
              hostSnapshot?.pendingApproval?.connectionId == connectionID,
              hostApprovalDecisionGate.beginDecision(connectionID: connectionID)
        else { return }

        hostStatusText = "正在处理连接请求…"
        hostErrorText = ""
        refreshHomeUI()
        var decisionErrorText: String?
        var decisionCanBeRetried = false
        do {
            try hostClient.resolvePendingApproval(
                connectionID: connectionID,
                decision: decision
            )
        } catch let error as HostControlError {
            switch error.approvalDecisionFailure {
            case .notFound, .alreadyFinalized:
                decisionErrorText = "连接请求已经结束。"
            case .expired:
                decisionErrorText = "连接请求已超时并被拒绝。"
            case nil:
                decisionErrorText = sanitizedHostError(error)
                decisionCanBeRetried = true
            }
        } catch {
            decisionErrorText = sanitizedHostError(error)
            decisionCanBeRetried = true
        }
        let snapshotRefreshed = refreshHostSnapshot()
        if decisionCanBeRetried,
           snapshotRefreshed,
           hostSnapshot?.pendingApproval?.connectionId == connectionID {
            hostApprovalDecisionGate.completeDecision(connectionID: connectionID)
        }
        if let decisionErrorText {
            hostErrorText = decisionErrorText
            refreshHomeUI()
        }
    }

    private func performHostSessionAction(
        connectionID: String,
        action: HostSessionHomeAction
    ) {
        guard hostRuntimeActive,
              let hostClient,
              hostSnapshot?.activeSession?.connectionId == connectionID
        else { return }

        let intent: HostSessionCommandIntent
        switch action {
        case .disableKeyboardAndMouse: intent = .disable(.keyboardAndMouse)
        case .disableClipboard: intent = .disable(.clipboard)
        case .disableSystemAudio: intent = .disable(.systemAudio)
        case .disconnect: intent = .disconnect
        }
        guard hostSessionCommandGate.begin(
            connectionID: connectionID,
            intent: intent
        ) else { return }

        hostErrorText = ""
        syncHostSessionStatusItem()
        refreshHomeUI()
        var actionErrorText: String?
        do {
            switch intent {
            case .disable(let capability):
                try hostClient.disableActiveSessionCapability(
                    capability,
                    connectionID: connectionID
                )
            case .disconnect:
                try hostClient.disconnectSession(connectionID: connectionID)
            }
        } catch let error as HostControlError {
            switch error.sessionCommandFailure {
            case .notFound:
                actionErrorText = "远程会话已经结束。"
            case .staleConnection:
                actionErrorText = "远程会话已更新，请按当前状态重试。"
            case .unavailable:
                actionErrorText = "当前会话暂时无法接收本机控制操作。"
            case nil:
                actionErrorText = sanitizedHostError(error)
            }
        } catch {
            actionErrorText = sanitizedHostError(error)
        }

        refreshHostSnapshot()
        if let actionErrorText {
            hostSessionCommandGate.complete(
                connectionID: connectionID,
                intent: intent
            )
            hostErrorText = actionErrorText
            syncHostSessionStatusItem()
            refreshHomeUI()
        }
    }

    private func syncHostSessionStatusItem() {
        guard let session = hostSnapshot?.activeSession,
              let presentation = HostSessionIndicatorPolicy.presentation(
                  connectionID: session.connectionId,
                  remoteID: session.remoteId,
                  remoteName: session.remoteName,
                  inputAvailability: session.inputAvailability,
                  inputUnavailableReason: session.inputUnavailableReason,
                  disconnectInFlight: hostSessionCommandGate.resolvingIntent(
                      connectionID: session.connectionId
                  ) == .disconnect
              )
        else {
            removeHostSessionStatusItem()
            return
        }

        if hostSessionStatusItem != nil,
           hostSessionIndicatorPresentation == presentation {
            return
        }
        hostSessionIndicatorPresentation = presentation

        let statusItem = hostSessionStatusItem
            ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        hostSessionStatusItem = statusItem
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "display",
                accessibilityDescription: presentation.title
            )
            button.image?.isTemplate = true
            button.toolTip = presentation.title
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: presentation.title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let identityItem = NSMenuItem(
            title: presentation.remoteIdentityText,
            action: nil,
            keyEquivalent: ""
        )
        identityItem.isEnabled = false
        menu.addItem(identityItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "打开 FarPane",
            action: #selector(openFarPaneFromStatusItem(_:)),
            keyEquivalent: ""
        )
        openItem.target = self
        openItem.isEnabled = true
        menu.addItem(openItem)

        let disconnectItem = NSMenuItem(
            title: presentation.disconnectTitle,
            action: #selector(disconnectHostSessionFromStatusItem(_:)),
            keyEquivalent: ""
        )
        disconnectItem.target = self
        disconnectItem.representedObject = presentation.connectionID
        disconnectItem.isEnabled = presentation.disconnectEnabled
        menu.addItem(disconnectItem)
        statusItem.menu = menu
    }

    private func removeHostSessionStatusItem() {
        hostSessionIndicatorPresentation = nil
        guard let statusItem = hostSessionStatusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        hostSessionStatusItem = nil
    }

    @objc private func openFarPaneFromStatusItem(_ sender: NSMenuItem) {
        bringMainWindowForward()
    }

    @objc private func disconnectHostSessionFromStatusItem(_ sender: NSMenuItem) {
        guard let connectionID = sender.representedObject as? String else { return }
        performHostSessionAction(connectionID: connectionID, action: .disconnect)
    }

    private func recordHostMediaLiveLog() {
        guard let writer = hostMediaLiveLogWriter,
              let telemetry = hostMediaPipeline?.telemetry else { return }
        do {
            try writer.record(snapshot: telemetry.snapshot())
        } catch {
            hostMediaLiveLogWriter = nil
            fputs("Host media live log write failed.\n", stderr)
        }
    }

    private func recordHostRuntimeStateEvidence(force: Bool = false) {
        guard let writer = hostRuntimeStateEvidenceWriter else { return }
        let snapshotObservedAt = hostSnapshot.flatMap { snapshot in
            snapshot.observedAt > 0 ? snapshot.observedAt : nil
        }
        do {
            try writer.record(
                hostRuntimeActive: hostRuntimeActive,
                hostState: hostSnapshot?.hostState ?? "unavailable",
                registrationStatus: hostSnapshot?.registrationStatus ?? "unavailable",
                hostSnapshotObservedAtUnixMilliseconds: snapshotObservedAt,
                mediaRouteActive: hostMediaRoute != nil,
                mediaPipelineActive: hostMediaPipeline != nil,
                force: force
            )
        } catch {
            hostRuntimeStateEvidenceWriter = nil
            fputs("Host runtime-state evidence write failed.\n", stderr)
        }
    }

    private func handleHostCoreEvent(_ event: HostCoreEvent) {
        if let control = event.mediaControl {
            handleHostMediaControl(control)
        }
        if let diagnostic = event.mediaDiagnostic {
            handleHostMediaDiagnostic(diagnostic)
        }
        if let queueDiagnostic = event.mediaQueueDiagnostic {
            handleHostMediaQueueDiagnostic(queueDiagnostic)
        }
        if let writerDiagnostic = event.mediaWriterDiagnostic {
            handleHostMediaWriterDiagnostic(writerDiagnostic)
        }
        if let networkDiagnostic = event.mediaNetworkDiagnostic {
            handleHostMediaNetworkDiagnostic(networkDiagnostic)
        }
        if let transportDiagnostic = event.mediaTransportDiagnostic {
            handleHostMediaTransportDiagnostic(transportDiagnostic)
        }
        refreshHostSnapshot()
    }

    private func configureHostMediaCapabilitiesIfNeeded(
        snapshot: HostCoreSnapshot,
        client: HostControlClient
    ) {
        guard !snapshot.hostInstanceId.isEmpty,
              hostMediaCapabilitiesInstanceID != snapshot.hostInstanceId else { return }
        hostMediaCapabilitiesInstanceID = snapshot.hostInstanceId
        guard let target = hostMediaCapabilityTarget() else {
            hostErrorText = "无法为当前显示器建立安全的视频硬件能力探测。"
            return
        }
        hostMediaCapabilitiesProbeTask?.cancel()
        let probeID = UUID()
        let instanceID = snapshot.hostInstanceId
        hostMediaCapabilitiesProbeID = probeID
        hostMediaStatusText = "正在验证本机硬件编码能力…"
        hostMediaCapabilitiesProbeTask = Task { @MainActor [weak self, weak client] in
            let discovered = await HostHardwareEncoderCapabilityDiscovery.discover(
                target: target
            )
            guard let self,
                  self.hostMediaCapabilitiesProbeID == probeID,
                  self.hostRuntimeActive,
                  self.hostMediaCapabilitiesInstanceID == instanceID,
                  self.hostSnapshot?.hostInstanceId == instanceID,
                  self.hostClient === client,
                  let client else { return }
            self.hostMediaCapabilitiesProbeTask = nil
            self.hostMediaCapabilitiesProbeID = nil
            guard let discovered else {
                self.hostMediaStatusText = nil
                self.hostErrorText = "当前显示器尺寸没有通过视频硬件编码首帧验证。"
                self.refreshHomeUI()
                return
            }
            do {
                try client.setMediaCapabilities(
                    hostInstanceID: instanceID,
                    capabilities: HostEncoderCapabilities(
                        h264Hardware: discovered.h264Hardware,
                        h265Hardware: discovered.h265Hardware,
                        maxWidth: UInt32(discovered.maxWidth),
                        maxHeight: UInt32(discovered.maxHeight),
                        maxFPS: UInt32(discovered.maxFPS)
                    )
                )
                self.hostMediaStatusText = nil
            } catch {
                self.hostMediaStatusText = nil
                self.hostErrorText = self.sanitizedHostError(error)
            }
            self.refreshHomeUI()
        }
    }

    private func hostMediaCapabilityTarget() -> HostHardwareEncoderCapabilityTarget? {
        let displays = NSScreen.screens.compactMap { screen -> (Int, Int, Int)? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let width = CGDisplayPixelsWide(displayID)
            let height = CGDisplayPixelsHigh(displayID)
            guard width > 0, height > 0 else { return nil }
            return (width, height, screen.maximumFramesPerSecond)
        }
        guard !displays.isEmpty else { return nil }
        return HostHardwareEncoderCapabilityTarget(
            width: displays.map(\.0).max() ?? 0,
            height: displays.map(\.1).max() ?? 0,
            maximumFramesPerSecond: min(60, max(1, displays.map(\.2).max() ?? 60))
        )
    }

    private func handleHostMediaControl(_ control: HostMediaControl) {
        switch control.command {
        case .startCapture:
            hostMediaStatusText = "控制端已订阅，正在准备画面…"
        case .stopCapture:
            guard hostMediaRoute?.matchesRoute(control) == true else { return }
            stopHostMediaPipeline()
        case .requestIdr:
            guard hostMediaRoute?.matchesRoute(control) == true else { return }
            if control.reason == "remoteRefresh" {
                hostMediaStatusText = "远端请求刷新，正在生成关键帧…"
            }
            hostMediaPipeline?.requestKeyframe()
        case .reconfigure:
            startHostMediaPipeline(control: control)
        }
    }

    private func syncHostMediaCaptureAvailability(activeSession: HostActiveSession?) {
        guard hostMediaRoute != nil else { return }
        if activeSession == nil || !HostActiveAquaSessionAuthority.currentSessionIsAvailable() {
            suspendHostMediaPipelineForSessionUnavailable()
        } else {
            resumeHostMediaPipelineAfterSessionRecovery()
        }
    }

    private func handleHostMediaDiagnostic(_ diagnostic: HostMediaDiagnostic) {
        guard let route = hostMediaRoute, diagnostic.matchesRoute(route) else { return }
        switch diagnostic.kind {
        case .firstPacketDispatched:
            hostMediaStatusText = "媒体帧已进入 Rust 发送链路"
        case .firstPacketAcknowledged:
            hostMediaStatusText = "媒体帧已获远端确认"
        case .refreshKeyframeDispatched:
            if diagnostic.isKeyframe && diagnostic.hasParameterSets {
                hostMediaStatusText = "刷新关键帧已发送"
            } else {
                hostErrorText = "刷新关键帧缺少必要的编码参数集。"
            }
        }
        refreshHomeUI()
    }

    private func handleHostMediaQueueDiagnostic(
        _ diagnostic: HostMediaQueueDiagnostic
    ) {
        guard let route = hostMediaRoute,
              diagnostic.matchesRoute(route),
              let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordEncodedQueueDepth(
            current: Int(diagnostic.currentDepth),
            maximum: Int(diagnostic.maximumDepth),
            capacity: Int(diagnostic.capacity),
            finalized: diagnostic.kind == .routeStopped
        )
    }

    private func handleHostMediaWriterDiagnostic(
        _ diagnostic: HostMediaWriterDiagnostic
    ) {
        guard let route = hostMediaRoute,
              diagnostic.matchesRoute(route),
              let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordWriterTiming(
            cycles: diagnostic.cycles,
            subscriberDispatches: diagnostic.subscriberDispatches,
            dispatchWallTotalUS: diagnostic.dispatchWallTotalUS,
            maximumDispatchWallUS: diagnostic.maximumDispatchWallUS,
            confirmationWaitTotalUS: diagnostic.confirmationWaitTotalUS,
            maximumConfirmationWaitUS: diagnostic.maximumConfirmationWaitUS,
            completedConfirmations: diagnostic.completedConfirmations,
            timedOutConfirmations: diagnostic.timedOutConfirmations,
            finalized: diagnostic.kind == .routeStopped
        )
    }

    private func handleHostMediaNetworkDiagnostic(
        _ diagnostic: HostMediaNetworkDiagnostic
    ) {
        guard let route = hostMediaRoute,
              diagnostic.matchesRoute(route),
              let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordNetworkMetrics(
            subscriberCount: Int(diagnostic.subscriberCount),
            qosSubscriberCount: Int(diagnostic.qosSubscriberCount),
            delaySampledSubscribers: Int(diagnostic.delaySampledSubscribers),
            rttSampledSubscribers: Int(diagnostic.rttSampledSubscribers),
            responseDelayedSubscribers: Int(diagnostic.responseDelayedSubscribers),
            networkDelayMS: diagnostic.worstNetworkDelayMS.map(Int.init),
            roundTripTimeMS: diagnostic.worstRTTMS.map(Int.init),
            finalized: diagnostic.kind == .routeStopped
        )
    }

    private func handleHostMediaTransportDiagnostic(
        _ diagnostic: HostMediaTransportDiagnostic
    ) {
        guard let route = hostMediaRoute,
              diagnostic.matchesRoute(route),
              let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordTransportMetrics(
            subscriberCount: Int(diagnostic.subscriberCount),
            directSubscribers: Int(diagnostic.directSubscribers),
            relaySubscribers: Int(diagnostic.relaySubscribers),
            unknownSubscribers: Int(diagnostic.unknownSubscribers),
            finalized: diagnostic.kind == .routeStopped
        )
    }

    private func startHostMediaPipeline(control: HostMediaControl) {
        guard let selectedCodec = control.codec else {
            hostErrorText = "Host 媒体 codec 缺失，已拒绝开始采集。"
            refreshHomeUI()
            return
        }
        let pipelineCodec: HostPipelineCodec
        switch selectedCodec {
        case .h264: pipelineCodec = .h264
        case .h265: pipelineCodec = .h265
        }
        guard hostRuntimeActive,
              let width = control.width,
              let height = control.height,
              let framesPerSecond = control.framesPerSecond,
              width > 0,
              height > 0,
              framesPerSecond > 0,
              control.displayID <= UInt64(Int.max),
              let snapshot = hostSnapshot,
              let client = hostClient else {
            hostErrorText = "Host 媒体参数无效，已拒绝开始采集。"
            refreshHomeUI()
            return
        }
        if snapshot.activeSession == nil
            || !HostActiveAquaSessionAuthority.currentSessionIsAvailable() {
            stopHostMediaPipeline()
            hostMediaRoute = control
            hostMediaSuspendedForSessionUnavailable = true
            hostMediaStatusText = "当前 Mac 会话不可用，画面采集已暂停"
            recordHostRuntimeStateEvidence(force: true)
            refreshHomeUI()
            return
        }
        stopHostMediaPipeline()
        hostMediaGeneration &+= 1
        let generation = hostMediaGeneration
        let fallbackBitRate = max(
            1_000_000,
            min(40_000_000, Int(width) * Int(height) * Int(framesPerSecond) / 10)
        )
        let requestedBitRate = Int(control.bitRate ?? 0)
        let bitRate = requestedBitRate > 0 ? requestedBitRate : fallbackBitRate
        let route = control
        let pipelineConfiguration = HostMediaPipelineConfiguration(
            codec: pipelineCodec,
            displayIndex: Int(control.displayID),
            width: Int(width),
            height: Int(height),
            framesPerSecond: Int(framesPerSecond),
            bitRate: bitRate
        )
        let telemetry = HostMediaTelemetry(configuration: pipelineConfiguration)
        telemetry.markDropReasonsInstrumented([.networkBackpressure])
        let evidenceWriter: HostMediaTelemetryEvidenceWriter?
        do {
            evidenceWriter = try HostMediaTelemetryEvidenceWriter.configured()
        } catch {
            evidenceWriter = nil
            fputs("Host telemetry evidence output is invalid or already exists.\n", stderr)
        }
        let liveLogWriter: HostMediaTelemetryLiveLogWriter?
        do {
            liveLogWriter = try HostMediaTelemetryLiveLogWriter.makeDefault()
        } catch {
            liveLogWriter = nil
            fputs("Host media live log could not be created.\n", stderr)
        }
        let pipelineReference = HostMediaPipelineReference()
        let pipeline = HostMediaPipeline(
            configuration: pipelineConfiguration,
            telemetry: telemetry,
            onAccessUnit: { [weak client] accessUnit in
                guard let client else { return }
                let packetCodec: HostMediaCodec = accessUnit.codec == .h264 ? .h264 : .h265
                telemetry.record(
                    .sendSubmit,
                    presentationTimeUS: accessUnit.presentationTimeUS,
                    byteCount: accessUnit.data.count
                )
                do {
                    try client.submit(accessUnit: HostEncodedAccessUnit(
                        hostInstanceID: snapshot.hostInstanceId,
                        connectionEpoch: route.connectionEpoch,
                        codecEpoch: route.codecEpoch,
                        displayID: route.displayID,
                        displayRevision: route.displayRevision,
                        codec: packetCodec,
                        framing: .avcc,
                        presentationTimeUS: accessUnit.presentationTimeUS,
                        isKeyframe: accessUnit.isKeyframe,
                        hasParameterSets: accessUnit.hasParameterSets,
                        data: accessUnit.data
                    ))
                    telemetry.record(
                        .sendAccepted,
                        presentationTimeUS: accessUnit.presentationTimeUS,
                        byteCount: accessUnit.data.count
                    )
                } catch let error as HostControlError where error.isExpectedMediaDrop {
                    // Queue backpressure may reject an encoded reference
                    // packet. Reset this route's encoder generation so old
                    // callbacks stop and the replacement begins with an IDR.
                    telemetry.record(
                        .sendDropped,
                        presentationTimeUS: accessUnit.presentationTimeUS,
                        byteCount: accessUnit.data.count
                    )
                    if let reason = error.mediaSubmissionDropReason {
                        telemetry.recordDrop(reason.telemetryReason)
                    } else {
                        telemetry.recordUnclassifiedDrop()
                    }
                    if error.requiresMediaKeyframeRecovery {
                        pipelineReference.recoverFromEncodedPacketDrop()
                    }
                } catch {
                    telemetry.record(
                        .sendDropped,
                        presentationTimeUS: accessUnit.presentationTimeUS,
                        byteCount: accessUnit.data.count
                    )
                    if let hostError = error as? HostControlError,
                       let reason = hostError.mediaSubmissionDropReason {
                        telemetry.recordDrop(reason.telemetryReason)
                    } else {
                        telemetry.recordUnclassifiedDrop()
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard self?.hostMediaGeneration == generation else { return }
                        self?.hostErrorText = self?.sanitizedHostError(error) ?? ""
                        self?.refreshHomeUI()
                    }
                }
            },
            onState: { [weak client] state in
                try? client?.reportEncoderState(
                    hostInstanceID: snapshot.hostInstanceId,
                    connectionEpoch: route.connectionEpoch,
                    codecEpoch: route.codecEpoch,
                    codec: selectedCodec,
                    hardwareAccelerated: state.hardwareAccelerated,
                    softwareFallback: state.softwareFallback,
                    encoderID: state.encoderID
                )
            },
            onError: { [weak self] _ in
                DispatchQueue.main.async {
                    guard self?.hostMediaGeneration == generation else { return }
                    self?.hostErrorText = "屏幕采集或硬件编码暂时不可用。"
                    self?.refreshHomeUI()
                }
            }
        )
        pipelineReference.bind(pipeline)
        hostMediaPipeline = pipeline
        hostMediaEvidenceWriter = evidenceWriter
        hostMediaLiveLogWriter = liveLogWriter
        hostMediaRoute = control
        hostMediaStatusText = "正在采集并编码画面…"
        if let liveLogWriter {
            do {
                try liveLogWriter.record(
                    snapshot: telemetry.snapshot(),
                    event: .routeStarted
                )
            } catch {
                hostMediaLiveLogWriter = nil
                fputs("Host media live log write failed.\n", stderr)
            }
        }
        recordHostRuntimeStateEvidence(force: true)
        Task { [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            do {
                try await pipeline.start()
            } catch {
                await pipeline.stop()
                if let evidenceWriter {
                    do {
                        try evidenceWriter.write(snapshot: telemetry.snapshot())
                    } catch {
                        fputs("Host telemetry evidence write failed.\n", stderr)
                    }
                }
                if let liveLogWriter {
                    do {
                        try liveLogWriter.record(
                            snapshot: telemetry.snapshot(),
                            event: .routeStartFailed
                        )
                    } catch {
                        fputs("Host media live log write failed.\n", stderr)
                    }
                }
                await MainActor.run {
                    guard self.hostMediaGeneration == generation else { return }
                    self.hostMediaPipeline = nil
                    self.hostMediaEvidenceWriter = nil
                    self.hostMediaLiveLogWriter = nil
                    self.hostMediaRoute = nil
                    self.hostMediaStatusText = nil
                    self.hostErrorText = "无法开始屏幕采集，请检查屏幕录制权限。"
                    self.recordHostRuntimeStateEvidence(force: true)
                    self.refreshHomeUI()
                }
            }
        }
    }

    private func suspendHostMediaPipelineForSessionUnavailable() {
        guard !hostMediaSuspendedForSessionUnavailable || hostMediaPipeline != nil else { return }
        guard let route = hostMediaRoute else { return }
        hostMediaSuspendedForSessionUnavailable = true
        guard let pipeline = hostMediaPipeline else {
            hostMediaStatusText = "当前 Mac 会话不可用，画面采集已暂停"
            recordHostRuntimeStateEvidence(force: true)
            return
        }

        hostMediaGeneration &+= 1
        let evidenceWriter = hostMediaEvidenceWriter
        let liveLogWriter = hostMediaLiveLogWriter
        hostMediaPipeline = nil
        hostMediaEvidenceWriter = nil
        hostMediaLiveLogWriter = nil
        hostMediaStatusText = "当前 Mac 会话不可用，画面采集已暂停"
        recordHostRuntimeStateEvidence(force: true)
        pipeline.cancel()
        Task {
            await pipeline.stop()
            if let evidenceWriter {
                do {
                    try evidenceWriter.write(snapshot: pipeline.telemetry.snapshot())
                } catch {
                    fputs("Host telemetry evidence write failed.\n", stderr)
                }
            }
            if let liveLogWriter {
                do {
                    try liveLogWriter.record(
                        snapshot: pipeline.telemetry.snapshot(),
                        event: .captureSuspended
                    )
                } catch {
                    fputs("Host media live log write failed.\n", stderr)
                }
            }
        }
        // The Rust route remains authoritative while only the process-local
        // capture/encoder pipeline is stopped. This exact route is reused when
        // the same Aqua session becomes available again.
        hostMediaRoute = route
    }

    private func resumeHostMediaPipelineAfterSessionRecovery() {
        guard hostMediaSuspendedForSessionUnavailable,
              hostMediaPipeline == nil,
              let route = hostMediaRoute else { return }
        hostMediaSuspendedForSessionUnavailable = false
        hostMediaStatusText = "当前 Mac 会话已恢复，正在恢复画面…"
        startHostMediaPipeline(control: route)
    }

    private func stopHostMediaPipeline() {
        hostMediaGeneration &+= 1
        let pipeline = hostMediaPipeline
        let evidenceWriter = hostMediaEvidenceWriter
        let liveLogWriter = hostMediaLiveLogWriter
        hostMediaPipeline = nil
        hostMediaEvidenceWriter = nil
        hostMediaLiveLogWriter = nil
        hostMediaRoute = nil
        hostMediaSuspendedForSessionUnavailable = false
        hostMediaStatusText = nil
        recordHostRuntimeStateEvidence(force: true)
        pipeline?.cancel()
        if let pipeline {
            Task {
                await pipeline.stop()
                if let evidenceWriter {
                    do {
                        try evidenceWriter.write(snapshot: pipeline.telemetry.snapshot())
                    } catch {
                        fputs("Host telemetry evidence write failed.\n", stderr)
                    }
                }
                if let liveLogWriter {
                    do {
                        try liveLogWriter.record(
                            snapshot: pipeline.telemetry.snapshot(),
                            event: .routeStopped
                        )
                    } catch {
                        fputs("Host media live log write failed.\n", stderr)
                    }
                }
            }
        }
    }

    private func revealHostTemporaryPassword() {
        guard hostRuntimeActive, let hostClient else { return }
        if !hostTemporaryPassword.isEmpty {
            hostTemporaryPassword = ""
            hostPasswordHideTimer?.invalidate()
            hostPasswordHideTimer = nil
            refreshHomeUI()
            return
        }
        do {
            try hostClient.command("revealTemporaryPassword")
            let snapshot = try hostClient.copySnapshot()
            hostSnapshot = snapshot
            hostTemporaryPassword = snapshot.revealedTemporaryPassword ?? ""
            hostPasswordHideTimer?.invalidate()
            hostPasswordHideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                self?.hostTemporaryPassword = ""
                self?.refreshHomeUI()
            }
            hostErrorText = ""
        } catch {
            hostTemporaryPassword = ""
            hostErrorText = sanitizedHostError(error)
        }
        refreshHomeUI()
    }

    private func regenerateHostTemporaryPassword() {
        guard hostRuntimeActive, let hostClient else { return }
        do {
            try hostClient.command("regenerateTemporaryPassword")
            hostTemporaryPassword = ""
            hostPasswordHideTimer?.invalidate()
            hostPasswordHideTimer = nil
            hostErrorText = ""
            refreshHostSnapshot()
        } catch {
            hostErrorText = sanitizedHostError(error)
            refreshHomeUI()
        }
    }

    private func presentHostPermanentPassword() {
        guard hostRuntimeActive,
              let hostClient,
              let policy = hostSnapshot?.passwordPolicy,
              policy.changeAllowed,
              let window else { return }
        let prompt = HostPermanentPasswordPromptController()
        hostPermanentPasswordPrompt = prompt
        prompt.begin(on: window, policy: policy) { [weak self] secret in
            guard let self else {
                secret?.wipe()
                return
            }
            self.hostPermanentPasswordPrompt = nil
            guard let secret else { return }
            defer { secret.wipe() }
            guard self.hostRuntimeActive, self.hostClient === hostClient else {
                self.hostErrorText = "Host 状态已变化，请重新设置永久密码。"
                self.refreshHomeUI()
                return
            }
            do {
                try hostClient.setPermanentPassword(&secret.data)
                self.hostErrorText = ""
                self.refreshHostSnapshot()
            } catch {
                self.hostErrorText = self.sanitizedHostError(error)
                self.refreshHomeUI()
            }
        }
    }

    private func confirmClearHostPermanentPassword() {
        guard hostRuntimeActive,
              let hostClient,
              let policy = hostSnapshot?.passwordPolicy,
              policy.changeAllowed,
              policy.localPasswordSet,
              let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除本机永久密码？"
        alert.informativeText = "清除后将不能再使用这个本机永久密码连接；临时密码不受影响。"
            + "如果管理员预设了密码，预设密码仍会生效。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self, weak hostClient] response in
            guard response == .alertFirstButtonReturn,
                  let self,
                  let hostClient,
                  self.hostRuntimeActive,
                  self.hostClient === hostClient else { return }
            do {
                try hostClient.command("clearPermanentPassword")
                self.hostErrorText = ""
                self.refreshHostSnapshot()
            } catch {
                self.hostErrorText = self.sanitizedHostError(error)
                self.refreshHomeUI()
            }
        }
    }

    private func sanitizedHostError(_ error: Error) -> String {
        switch error {
        case HostControlError.load, HostControlError.hostSurfaceUnavailable:
            return "无法加载兼容的 Host Core。"
        case HostControlError.abiMismatch,
             HostControlError.mediaABIMismatch,
             HostControlError.invalidUpstreamCommit:
            return "Host Core 版本不匹配。"
        case HostControlError.configRoot:
            return "Host 配置目录初始化失败。"
        case HostControlError.create, HostControlError.start:
            return "Host 服务启动失败，请检查服务器配置。"
        case HostControlError.command:
            return "Host 设置操作失败，请重试。"
        case HostControlError.permanentPassword:
            let failure = (error as? HostControlError)?.permanentPasswordFailure
            switch failure {
            case .empty, .tooShort:
                return "永久密码长度不足。"
            case .tooLong:
                return "永久密码过长。"
            case .outerWhitespace:
                return "永久密码首尾不能是空白字符。"
            case .invalidUTF8, .forbiddenCharacter:
                return "永久密码包含不支持的字符。"
            case .changeDisabled:
                return "永久密码由管理员管理，当前不允许更改。"
            case .storage:
                return "永久密码未能安全保存，请重试。"
            case .unknown, .none:
                return "永久密码设置失败，请重试。"
            }
        case HostControlError.snapshot, HostControlError.snapshotDecode:
            return "Host 状态暂时无法读取。"
        case HostControlError.stop:
            return "Host 服务未能正常停止。"
        case HostControlError.media:
            return "Host 媒体链暂时不可用。"
        default:
            return "Host 服务暂时不可用。"
        }
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
        if hostRuntimeActive || hostClient != nil {
            stopHostMode(preservePreference: true, reason: .userRequest, releaseClient: true)
        }
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
        let serverChanged = catalog.server != updated.server
        do {
            try catalogStore.save(updated)
            catalog = updated
            homeErrorText = ""
            if serverChanged,
               UserDefaults.standard.bool(forKey: Self.hostEnabledDefaultsKey) {
                stopHostMode(preservePreference: true, reason: .userRequest)
                startHostMode()
            }
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
        window.title = fixture == nil ? "FarPane" : "FarPane — Fixture"
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
        guard !didFinish else { return }
        didFinish = true
        stopHostMode(preservePreference: true, reason: .appExit, releaseClient: true)
        guard let metrics else { return }
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
