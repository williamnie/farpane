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
    func launchViewer(
        fixture: String?, liveConfiguration: (URL, CoreConnectionConfig)?, attemptID: UUID?
    ) throws {
        let screenFrame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 720)
        let windowFrame =
            automatedRun && options.fullscreen
            ? screenFrame : NSRect(x: 0, y: 0, width: 1280, height: 720)
        let view = ViewerMetalView(frame: windowFrame)
        let displayID =
            (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
        let provisionalDevice = MetalVideoRenderer.selectDevice(options.gpu, displayID: displayID)
        guard let deviceName = provisionalDevice?.name else { throw MetalRendererError.noDevice }
        let metrics = PipelineMetrics(
            inputWidth: options.width, inputHeight: options.height, inputFPS: options.fps,
            selectedGPU: deviceName, source: fixture == nil ? "rustdesk-live" : "fixture")
        let renderer = try MetalVideoRenderer(
            view: view, preference: options.gpu, displayID: displayID, metrics: metrics)
        let chrome = ViewerChromeView(
            videoView: view, metrics: metrics,
            showsAcceptanceControls: automatedRun && fixture == nil,
            showsFileTransferControls: liveConfiguration != nil,
            showsDisplayControls: liveConfiguration != nil,
            showsAudioStatus: liveConfiguration != nil)
        let window =
            self.window
            ?? NSWindow(
                contentRect: windowFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = fixture == nil ? "FarPane" : "FarPane — Fixture"
        window.minSize = NSSize(width: 720, height: 480)
        let isFullScreen = window.styleMask.contains(.fullScreen)
        window.contentView = chrome
        if ProductWindowTransitionPolicy.shouldResetWindowedContentSize(isFullScreen: isFullScreen)
        {
            window.setContentSize(windowFrame.size)
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
        self.renderer = renderer
        self.metrics = metrics
        viewerView = view
        viewerChrome = chrome
        homeView = nil
        startedAt = Date()

        let sendKey: @Sendable (CoreKeyEvent) -> Int32 = { [weak self] event in
            self?.coreClient?.sendKey(event) ?? -3
        }
        let recordInputResult: @Sendable (String, Int32) -> Void = {
            [weak chrome, weak metrics] category, status in
            if status == 0 {
                metrics?.recordInput(category: category, accepted: true)
            } else if status == -6 {
                metrics?.recordInput(category: category, accepted: false)
            }
            if status == -6 {
                DispatchQueue.main.async { chrome?.updateState("远端尚未授予键盘与鼠标控制权限", isError: true) }
            }
        }
        view.sendPointer = { [weak self] event in self?.coreClient?.sendPointer(event) ?? -3 }
        view.sendKey = sendKey
        view.sendText = { [weak self] text in self?.coreClient?.sendText(text) ?? -3 }
        view.recordInputResult = recordInputResult
        if liveConfiguration != nil {
            let keyboardController = ExclusiveKeyboardController(
                sendKey: sendKey, recordInputResult: recordInputResult)
            keyboardController.onStatusChange = {
                [weak chrome, weak view] active, resumePending, message, isError, didActivate in
                view?.setKeyboardInputEnabled(!active)
                chrome?.updateKeyboardGrab(
                    active: active, resumePending: resumePending, message: message, isError: isError
                )
                if didActivate { metrics.recordExclusiveKeyboardActivation() }
                if isError { metrics.recordExclusiveKeyboardFailure() }
            }
            chrome.onToggleKeyboardGrab = { [weak keyboardController] in
                keyboardController?.toggle()
            }
            chrome.onOpenKeyboardPermissions = { Self.openKeyboardPrivacySettings() }
            chrome.onControlOverlayVisibilityChanged = { [weak keyboardController] expanded in
                keyboardController?.setControlOverlayVisible(expanded)
            }
            view.onWindowResignKey = { [weak keyboardController] in
                keyboardController?.setWindowKey(false)
            }
            view.onWindowBecomeKey = { [weak keyboardController] in
                keyboardController?.setWindowKey(true)
            }
            keyboardController.setApplicationActive(NSApplication.shared.isActive)
            keyboardController.setWindowKey(window.isKeyWindow)
            self.keyboardController = keyboardController
        } else {
            keyboardController = nil
        }
        chrome.onToggleFullscreen = { [weak window] in window?.toggleFullScreen(nil) }
        chrome.onFileTransferAction = { [weak self] in self?.handleViewerFileTransferAction() }
        chrome.onFileTransferUploadAction = { [weak self] in
            self?.handleViewerFileTransferUploadAction()
        }
        chrome.onSelectDisplay = { [weak self] displayIndex in
            _ = self?.selectViewerDisplay(displayIndex: displayIndex)
        }
        chrome.onDisconnect = { [weak self] in self?.disconnectViewer() }

        if let fixture {
            try startFixture(fixture, renderer: renderer, metrics: metrics)
        } else if let liveConfiguration {
            try startLive(
                coreURL: liveConfiguration.0, configuration: liveConfiguration.1,
                renderer: renderer, metrics: metrics, viewer: view, chrome: chrome,
                attemptID: attemptID)
        }

        memoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak metrics] _ in
            metrics?.sampleMemory()
        }
        hudTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak chrome, weak metrics] _ in
            if let value = metrics?.hudSnapshot() { chrome?.updateHUD(value) }
        }
        if automatedRun {
            stopTimer = Timer.scheduledTimer(withTimeInterval: options.duration, repeats: false) {
                _ in NSApplication.shared.terminate(nil)
            }
        }
        if automatedRun, options.fullscreen {
            DispatchQueue.main.async { [weak window] in window?.toggleFullScreen(nil) }
        }
        print(
            "PIPELINE_STARTED source=\(fixture == nil ? "rustdesk-live" : "fixture") gpu=\(renderer.deviceName) fullscreen=\(options.fullscreen) duration=\(automatedRun ? options.duration : 0)"
        )
    }

    func startFixture(_ fixture: String, renderer: MetalVideoRenderer, metrics: PipelineMetrics)
        throws
    {
        guard options.width > 0, options.height > 0 else {
            throw usageError("--width and --height are required for fixture mode")
        }
        let fixtureURL = URL(fileURLWithPath: fixture)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw usageError("fixture not found: \(fixture)")
        }
        let player = try FixturePlayer(
            fixtureURL: fixtureURL, fps: options.fps, metrics: metrics,
            output: { [weak renderer] pixelBuffer, _ in renderer?.enqueue(pixelBuffer) })
        self.player = player
        player.start()
    }

    func startLive(
        coreURL: URL, configuration: CoreConnectionConfig, renderer: MetalVideoRenderer,
        metrics: PipelineMetrics, viewer: ViewerMetalView, chrome: ViewerChromeView,
        attemptID: UUID?
    ) throws {
        guard FileManager.default.fileExists(atPath: coreURL.path) else {
            throw usageError("core library not found: \(coreURL.path)")
        }

        let evidenceSessionEpoch = hostViewerConcurrencyEvidenceOwner.beginViewerSession()
        var viewerStarted = false
        defer {
            if !viewerStarted, let evidenceSessionEpoch {
                _ = hostViewerConcurrencyEvidenceOwner.stopViewerSession(
                    sessionEpoch: evidenceSessionEpoch)
            }
        }

        guard let clipboardSessionEpoch = nextViewerClipboardSessionEpoch(),
            viewerPasteboardOwner.begin(
                sessionEpoch: clipboardSessionEpoch,
                receiveTextEnabled: configuration.receiveClipboardText,
                sendTextEnabled: configuration.sendClipboardText,
                receiveRichTextEnabled: configuration.receiveClipboardRichText,
                sendRichTextEnabled: configuration.sendClipboardRichText,
                receiveImageEnabled: configuration.receiveClipboardImage,
                sendImageEnabled: configuration.sendClipboardImage,
                sendText: { [weak self] text in self?.coreClient?.sendClipboardText(text) ?? -3 },
                sendRichText: { [weak self] payload in
                    self?.coreClient?.sendClipboardRichText(payload) ?? -3
                },
                sendImage: { [weak self] payload in
                    self?.coreClient?.sendClipboardImage(payload) ?? -3
                })
        else { throw usageError("viewer clipboard lifecycle unavailable") }
        viewerClipboardSessionEpoch = clipboardSessionEpoch
        defer { if !viewerStarted { stopViewerClipboard() } }

        guard
            prepareViewerFileTransferComposition(coreURL: coreURL, baseConfiguration: configuration)
        else { throw usageError("viewer file-transfer lifecycle unavailable") }
        defer { if !viewerStarted { stopViewerFileTransfer() } }

        let decoder = LiveHEVCDecoder(
            metrics: metrics,
            output: { [weak renderer] pixelBuffer, _ in renderer?.enqueue(pixelBuffer) })
        let recovery = CoreRecoveryCoordinator()
        var recoveryStarted = false
        if let attemptID, let recoverySessionEpoch = nextViewerRecoverySessionEpoch() {
            let owner = ViewerAutomaticRecoveryOwner.makeProduct(
                attempt: { [weak self, weak viewer, weak chrome, weak decoder] sessionEpoch, _, _ in
                    guard let self, let viewer, let chrome, let decoder else { return .unavailable }
                    return self.attemptViewerAutomaticRecovery(
                        sessionEpoch: sessionEpoch, coreURL: coreURL, metrics: metrics,
                        viewer: viewer, chrome: chrome, decoder: decoder, recovery: recovery,
                        attemptID: attemptID, evidenceSessionEpoch: evidenceSessionEpoch)
                },
                exhausted: { [weak self] sessionEpoch in
                    self?.handleViewerAutomaticRecoveryExhausted(
                        sessionEpoch: sessionEpoch, attemptID: attemptID)
                })
            guard owner.begin(sessionEpoch: recoverySessionEpoch) else {
                throw usageError("viewer recovery lifecycle unavailable")
            }
            viewerRecoverySessionEpoch = recoverySessionEpoch
            viewerAutomaticRecoveryOwner = owner
            recoveryStarted = true
        }
        defer { if !viewerStarted, recoveryStarted { stopViewerAutomaticRecovery() } }

        try installViewerCoreClient(
            coreURL: coreURL, configuration: configuration, metrics: metrics, viewer: viewer,
            chrome: chrome, decoder: decoder, recovery: recovery, attemptID: attemptID,
            evidenceSessionEpoch: evidenceSessionEpoch)
        viewerEvidenceSessionEpoch = evidenceSessionEpoch
        viewerStarted = true
        liveDecoder = decoder
    }
}
