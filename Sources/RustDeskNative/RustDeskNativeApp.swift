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

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @unchecked Sendable {
    static let hostEnabledDefaultsKey = "farpane.host.enabled"
    static let hostAgentRegisteredBuildDefaultsKey = "farpane.host.agentRegistrationBuildID"
    static let hostFileTransferEnabledDefaultsKey = "farpane.host.fileTransfer.enabled"
    static let hostFileTransferReceiveRootDefaultsKey = "farpane.host.fileTransfer.receiveRoot"
    static let hostAudioEnabledDefaultsKey = "farpane.host.audio.enabled"
    static let hostAudioInputDeviceNameDefaultsKey = "farpane.host.audio.inputDeviceName"

    let options = Options(arguments: CommandLine.arguments)
    let hostViewerConcurrencyEvidenceOwner = HostViewerConcurrencyEvidenceProcessOwner()
    let hostAgentApplicationConcurrencyObservationState =
        HostAgentApplicationConcurrencyObservationState()
    let catalogStore = DeviceCatalogStore(fileURL: AppDelegate.catalogURL())
    lazy var hostAgentBootstrapIntegration = try? HostAgentBootstrapProductIntegration()
    lazy var hostAgentRuntimeConfigurationReader =
        try? HostAgentRuntimeConfigurationObservationReader()
    lazy var hostMicrophoneAuthorizationAuthority =
        HostMicrophoneAuthorizationAuthority.makeProduct()
    let hostAudioInputDeviceCatalogOwner = HostAudioInputDeviceCatalogOwner.makeProduct()
    let credentialStore: DeviceCredentialStore = KeychainDeviceCredentialStore(
        service: ProcessInfo.processInfo.environment["RDN_KEYCHAIN_SERVICE"]
            ?? KeychainDeviceCredentialStore.defaultService)
    var catalog = DeviceCatalogDocument()
    var catalogMutationBlocked = false
    var hostAgentBootstrapState: HostAgentBootstrapProductIntegrationState = .waitingForServer
    var homeErrorText = ""
    var activeAttemptID: UUID?
    var pendingProductConnection: PendingProductConnection?
    var window: NSWindow?
    var homeView: HomeView?
    var hostSessionStatusItem: NSStatusItem?
    var hostSessionIndicatorPresentation: HostSessionIndicatorPresentation?
    var passwordPrompt: PasswordPromptController?
    var hostPermanentPasswordPrompt: HostPermanentPasswordPromptController?
    var serverPrompt: ServerSettingsPromptController?
    var viewerChrome: ViewerChromeView?
    var viewerView: ViewerMetalView?
    var renderer: MetalVideoRenderer?
    var player: FixturePlayer?
    var liveDecoder: LiveHEVCDecoder?
    var coreClient: RustDeskCoreClient?
    var viewerSessionLog: ViewerSessionLiveLog?
    var viewerEvidenceSessionEpoch: UInt64?
    let viewerPasteboardOwner = ViewerPasteboardOwner()
    var viewerClipboardCommittedEpoch: UInt64 = 0
    var viewerClipboardSessionEpoch: UInt64?
    var viewerFileTransferComposition: ViewerFileTransferProductComposition?
    var viewerFileTransferCommittedEpoch: UInt64 = 0
    var viewerFileTransferConnectionContext: ViewerFileTransferConnectionContext?
    var viewerFileTransferCoreURL: URL?
    var viewerFileTransferActiveTransferID: Int32?
    var viewerFileTransferActiveDirection: ViewerFileTransferActionDirection?
    var viewerFileTransferActionConsumed = false
    var viewerOpenFileTransferUploadWhenStreaming = false
    var viewerFileTransferDestinationPicker: ViewerFileTransferDestinationPickerController?
    var viewerFileTransferUploadSourcePicker: ViewerFileTransferUploadSourcePickerController?
    var viewerFileTransferPasswordPrompt: ViewerFileTransferPasswordPromptController?
    var hostFileTransferReceiveRootPicker: HostFileTransferReceiveRootPickerController?
    var viewerAutomaticRecoveryOwner: ViewerAutomaticRecoveryOwner?
    var viewerRecoveryDeviceID: UUID?
    var viewerRecoveryCommittedEpoch: UInt64 = 0
    var viewerRecoverySessionEpoch: UInt64?
    var viewerCoreGeneration: UInt64 = 0
    var viewerAudioOptInForNextConnection = false
    var viewerSessionReceiveAudio = false
    var viewerAudioSessionOwner: ViewerAudioSessionOwner?
    var viewerDisplaySelectionInputOwner: ViewerDisplaySelectionInputOwner?
    var hostClient: HostControlClient?
    var hostRuntimeActive = false
    var hostRuntimeQuiescenceConfirmed = true
    var hostMediaPipeline: HostMediaPipeline?
    var hostMediaEvidenceWriter: HostMediaTelemetryEvidenceWriter?
    var hostMediaLiveLogWriter: HostMediaTelemetryLiveLogWriter?
    var hostRuntimeStateEvidenceWriter: HostRuntimeStateEvidenceWriter?
    var hostMediaRoute: HostMediaControl?
    var hostMediaSuspendedForSessionUnavailable = false
    var hostMediaStatusText: String?
    var hostFileTransferPolicyErrorText = ""
    var hostAudioPolicyErrorText = ""
    var hostMediaGeneration: UInt64 = 0
    var hostMediaCapabilitiesInstanceID = ""
    var hostMediaCapabilitiesProbeID: UUID?
    var hostMediaCapabilitiesProbeTask: Task<Void, Never>?
    var hostSnapshot: HostCoreSnapshot?
    var hostActiveAquaSessionAvailable: Bool?
    var hostApprovalDecisionGate = HostApprovalDecisionGate()
    var hostSessionCommandGate = HostSessionCommandGate()
    var hostTemporaryPassword = ""
    var hostAgentPasswordOperationOwner: HostAgentXPCPasswordOperationOwner?
    var hostAgentPasswordActionInFlight: HostAgentXPCPasswordAction?
    var hostAgentPasswordErrorText = ""
    var hostStatusText = "已关闭"
    var hostErrorText = ""
    var hostAgentBackgroundRegistrationPresentation: HostAgentBackgroundRegistrationPresentation?
    var hostAgentBackgroundUnregistrationPresentation:
        HostAgentBackgroundUnregistrationPresentation?
    var hostAgentBackgroundRegistrationStatus: HostAgentBackgroundRegistrationStatus =
        .serviceUnavailable
    var hostAgentBackgroundActivationView: HostAgentBackgroundActivationView?
    var hostAgentRuntimeConfigurationCoherence: HostAgentRuntimeConfigurationCoherence =
        .waitingForLivePeer
    var hostAgentBackgroundCommandPresentation = HostAgentBackgroundHomeCommandReadOnlyPresentation
        .unavailable
    var hostAgentBackgroundFlow: HostAgentBackgroundHomeFlow?
    var hostAgentBackgroundOwnershipErrorText = ""
    var hostAgentAutomaticRegistrationAttempted = false
    var hostAgentRegistrationRefreshAttempted = false
    var hostPollTimer: Timer?
    var hostPasswordHideTimer: Timer?
    var keyboardController: ExclusiveKeyboardController?
    var metrics: PipelineMetrics?
    var memoryTimer: Timer?
    var hudTimer: Timer?
    var stopTimer: Timer?
    var startedAt = Date()
    var didFinish = false
    var automatedRun = false
    lazy var hostAgentLegacyMigrationCoordinator = HostAgentLegacyHostMigrationCoordinator(
        captureEvidence: { [weak self] in
            guard Thread.isMainThread else {
                return HostAgentLegacyHostProductEvidencePolicy.unavailableEvidence
            }
            return MainActorBackport.assumeIsolated {
                self?.captureLegacyHostMigrationEvidence()
                    ?? HostAgentLegacyHostProductEvidencePolicy.unavailableEvidence
            }
        },
        requestQuiescence: { [weak self] in
            guard Thread.isMainThread else { return .failed }
            return MainActorBackport.assumeIsolated {
                self?.requestLegacyHostQuiescence() ?? .failed
            }
        })
    lazy var hostAgentBackgroundRegistrationMutationOwner =
        HostAgentBackgroundRegistrationMutationOwner.makeProduct()
    lazy var hostAgentBackgroundActivationOwner = HostAgentBackgroundActivationOwner.makeProduct(
        observer: { [weak self] view in
            DispatchQueue.main.async { [weak self] in
                self?.applyHostAgentBackgroundActivationView(view)
            }
        })
    lazy var hostAgentBackgroundCommandPresentationOwner =
        HostAgentBackgroundHomeCommandPresentationOwner.makeProduct(
            activationOwner: hostAgentBackgroundActivationOwner,
            observer: { [weak self] view in
                DispatchQueue.main.async { [weak self] in
                    self?.applyHostAgentBackgroundCommandPresentation(view)
                }
            })
    lazy var hostAgentBackgroundRegistrationSheetDriver =
        HostAgentBackgroundRegistrationSheetDriver.makeProduct(
            mutationOwner: hostAgentBackgroundRegistrationMutationOwner,
            performMigrationPreparation: { [weak self] in
                guard Thread.isMainThread else {
                    return (
                        false,
                        HostAgentLegacyHostMigrationCoordinatorView(
                            phase: .failed(.assessment(.evidenceUnavailable)))
                    )
                }
                return MainActorBackport.assumeIsolated {
                    self?.prepareLegacyHostForBackgroundRegistration() ?? (
                        false,
                        HostAgentLegacyHostMigrationCoordinatorView(
                            phase: .failed(.assessment(.evidenceUnavailable)))
                    )
                }
            },
            onUpdate: { [weak self] view in
                guard Thread.isMainThread else { return }
                MainActorBackport.assumeIsolated {
                    self?.applyHostAgentBackgroundRegistrationPresentation(view)
                }
            })
    lazy var hostAgentBackgroundUnregistrationSheetDriver =
        HostAgentBackgroundUnregistrationSheetDriver.makeProduct(
            mutationOwner: hostAgentBackgroundRegistrationMutationOwner,
            onUpdate: { [weak self] view in
                guard Thread.isMainThread else { return }
                MainActorBackport.assumeIsolated {
                    self?.applyHostAgentBackgroundUnregistrationPresentation(view)
                }
            })

    static func main() {
        switch RustDeskNativeProcessModePolicy.resolve(arguments: CommandLine.arguments) {
        case .hostAgent:
            guard HostAgentProcessPresentation.transformCurrentProcessToUIElement() else {
                exit(EXIT_FAILURE)
            }
            exit(HostAgentProcessBootstrap.run())
        case .unsupportedConnectionManager:
            fputs(RustDeskNativeConnectionManagerRejectionPolicy.diagnostic, stderr)
            exit(RustDeskNativeConnectionManagerRejectionPolicy.exitCode)
        case .application: break
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        _ = delegate.hostViewerConcurrencyEvidenceOwner.configureApplication()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        delegate.configureMainMenu(for: application)
        application.run()
    }

    func configureMainMenu(for application: NSApplication) {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)
        let applicationMenu = NSMenu(title: "FarPane")
        applicationMenuItem.submenu = applicationMenu

        let aboutItem = NSMenuItem(
            title: "关于 FarPane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        aboutItem.target = application
        applicationMenu.addItem(aboutItem)
        let logsItem = NSMenuItem(
            title: "打开诊断日志…", action: #selector(openDiagnosticLogs(_:)), keyEquivalent: "")
        logsItem.target = self
        applicationMenu.addItem(logsItem)
        applicationMenu.addItem(.separator())

        let hideItem = NSMenuItem(
            title: "隐藏 FarPane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = application
        applicationMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "隐藏其他应用", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        hideOthersItem.target = application
        applicationMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(
            title: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        showAllItem.target = application
        applicationMenu.addItem(showAllItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "退出 FarPane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = application
        applicationMenu.addItem(quitItem)

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu

        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(
            NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(
            NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(
            NSMenuItem(title: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(
            NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu

        let closeItem = NSMenuItem(
            title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(closeItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            NSMenuItem(
                title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"
            ))
        windowMenu.addItem(
            NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))

        application.mainMenu = mainMenu
        application.windowsMenu = windowMenu
    }

    static func catalogURL() -> URL {
        guard let override = ProcessInfo.processInfo.environment["RDN_CATALOG_PATH"],
            !override.isEmpty
        else { return DeviceCatalogStore.defaultFileURL() }
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
        do { try launch() } catch {
            fputs("RustDeskNative startup failed: \(error)\n", stderr)
            _ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()
            exit(2)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelBackgroundPasswordOperation()
        _ = hostAgentBackgroundRegistrationMutationOwner.apply(.unregisterBackgroundAgent)
        _ = hostAgentBackgroundActivationOwner.apply(.applicationWillTerminate)
        finish()
        _ = hostViewerConcurrencyEvidenceOwner.terminateAndWait()
    }

    func applicationDidResignActive(_ notification: Notification) {
        reconcileViewerKeyboardFocus(applicationActive: false)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        reconcileViewerKeyboardFocus(applicationActive: true)
        reconcileHostProductOwnership()
        MainActorBackport.assumeIsolated {
            if hostAudioPolicyChangeAllowed() { reconcileHostAgentBootstrap() }
            refreshHomeUI()
        }
        hostAgentBackgroundActivationOwner.refreshRegistration()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        reconcileViewerKeyboardFocus()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        reconcileViewerKeyboardFocus()
    }

    func reconcileViewerKeyboardFocus(applicationActive: Bool? = nil) {
        guard viewerChrome != nil, let window else { return }
        keyboardController?.reconcileFocus(
            applicationActive: applicationActive ?? NSApplication.shared.isActive,
            windowKey: window.isKeyWindow)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        HostApplicationLifecyclePolicy.shouldTerminateAfterLastWindowClosed(
            hostRuntimeActive: hostRuntimeActive)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        guard ProductWindowClosePolicy.shouldAllowClose(viewerSessionActive: viewerChrome != nil)
        else {
            disconnectViewer()
            return false
        }
        return true
    }

    func disconnectViewer() {
        if automatedRun { NSApplication.shared.terminate(nil) } else { showHomeUI() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        if !flag { bringMainWindowForward() }
        return true
    }

    func bringMainWindowForward() {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func launch() throws {
        if options.fixture == nil, options.coreLibrary == nil {
            prepareProductCatalog()
            showHomeUI(error: homeErrorText)
            return
        }
        automatedRun = true
        let liveConfiguration =
            options.fixture == nil ? try environmentConnectionConfiguration() : nil
        try launchViewer(
            fixture: options.fixture, liveConfiguration: liveConfiguration, attemptID: nil)
    }

    func usageError(_ message: String) -> NSError {
        NSError(domain: "RustDeskNative", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func finish() {
        guard !didFinish else { return }
        didFinish = true
        let hostReceiveRootPicker = hostFileTransferReceiveRootPicker
        hostFileTransferReceiveRootPicker = nil
        hostReceiveRootPicker?.cancel()
        stopHostMode(preservePreference: true, reason: .appExit, releaseClient: true)
        stopViewerAutomaticRecovery()
        stopViewerClipboard()
        stopViewerFileTransfer()
        stopViewerDisplaySelectionInput()
        _ = stopViewerLifecycleEvidence()
        guard let metrics else { return }
        player?.stop()
        keyboardController?.disable(message: nil, isError: false, notify: false)
        viewerView?.releaseAllInput()
        coreClient?.disconnect()
        liveDecoder?.invalidate()
        memoryTimer?.invalidate()
        hudTimer?.invalidate()
        stopTimer?.invalidate()
        stopViewerSessionLog()
        let report = metrics.snapshot(durationOverride: Date().timeIntervalSince(startedAt))
        do {
            let data = try JSONEncoder.pretty.encode(report)
            let url = URL(fileURLWithPath: options.output)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            print("BENCHMARK_WRITTEN \(url.path)")
        } catch { fputs("failed to write benchmark: \(error)\n", stderr) }
    }

    func stopViewerAutomaticRecovery() {
        viewerAutomaticRecoveryOwner?.cancelAndWait()
        viewerAutomaticRecoveryOwner = nil
        viewerRecoverySessionEpoch = nil
    }

    func stopViewerDisplaySelectionInput() {
        viewerDisplaySelectionInputOwner?.stop()
        viewerDisplaySelectionInputOwner = nil
    }

    func nextViewerClipboardSessionEpoch() -> UInt64? {
        guard viewerClipboardCommittedEpoch < UInt64.max else { return nil }
        viewerClipboardCommittedEpoch += 1
        return viewerClipboardCommittedEpoch
    }

    @discardableResult func stopViewerLifecycleEvidence() -> Bool {
        guard let sessionEpoch = viewerEvidenceSessionEpoch else { return false }
        viewerEvidenceSessionEpoch = nil
        return hostViewerConcurrencyEvidenceOwner.stopViewerSession(sessionEpoch: sessionEpoch)
    }
}
