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
    func installViewerCoreClient(
        coreURL: URL, configuration: CoreConnectionConfig, metrics: PipelineMetrics,
        viewer: ViewerMetalView, chrome: ViewerChromeView, decoder: LiveHEVCDecoder,
        recovery: CoreRecoveryCoordinator, attemptID: UUID?, evidenceSessionEpoch: UInt64?
    ) throws {
        guard viewerCoreGeneration < UInt64.max else {
            throw usageError("viewer core generation exhausted")
        }
        viewerCoreGeneration += 1
        let coreGeneration = viewerCoreGeneration
        let clipboardSessionEpoch = viewerClipboardSessionEpoch
        let fallbackFPS = options.fps
        let keyboardController = self.keyboardController
        let selectionWasQuiesced =
            viewerDisplaySelectionInputOwner?.snapshot().inputQuiesced ?? false
        viewerDisplaySelectionInputOwner?.stop()
        let displaySelectionInputOwner = ViewerDisplaySelectionInputOwner(
            initiallyQuiesced: selectionWasQuiesced,
            sendSelection: { [weak self] request in
                guard let self, self.viewerCoreGeneration == coreGeneration else { return -3 }
                return self.coreClient?.selectDisplay(request) ?? -3
            },
            quiesceInput: { [weak viewer, weak keyboardController] in
                MainActorBackport.assumeIsolated {
                    viewer?.releaseAllInputForDisplaySelection()
                    keyboardController?.setDisplaySelectionInputQuiesced(true)
                }
            },
            resumeInput: { [weak viewer, weak keyboardController] in
                MainActorBackport.assumeIsolated {
                    viewer?.resumeInputAfterDisplaySelection()
                    keyboardController?.setDisplaySelectionInputQuiesced(false)
                }
            })
        viewerDisplaySelectionInputOwner = displaySelectionInputOwner
        refreshViewerDisplaySelection(chrome: chrome)
        viewerAudioSessionOwner?.stop()
        let audioSessionOwner = ViewerAudioSessionOwner(receiveAudio: configuration.receiveAudio)
        viewerAudioSessionOwner = audioSessionOwner
        refreshViewerAudioSession(chrome: chrome)
        let client = try RustDeskCoreClient(
            libraryURL: coreURL,
            onState: { [weak self, weak chrome, weak keyboardController] event in
                DispatchQueue.main.async {
                    self?.handleViewerCoreState(
                        event, coreGeneration: coreGeneration, metrics: metrics, chrome: chrome,
                        keyboardController: keyboardController, attemptID: attemptID,
                        evidenceSessionEpoch: evidenceSessionEpoch)
                }
            },
            onRemotePermission: { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleViewerRemotePermission(
                        event, coreGeneration: coreGeneration, attemptID: attemptID)
                }
            },
            onVideo: { [weak viewer] packet in
                if packet.width > 0, packet.height > 0 {
                    let viewer = viewer
                    DispatchQueue.main.async {
                        viewer?.updateRemoteSize(
                            width: Int(packet.width), height: Int(packet.height))
                    }
                }
                Self.consume(
                    packet: packet, decoder: decoder, metrics: metrics, fallbackFPS: fallbackFPS,
                    recovery: recovery)
            },
            onMetrics: { value in
                metrics.recordCoreMetrics(
                    remoteFPS: value.remoteFPS, networkDelayMS: Int(value.networkDelayMS),
                    targetBitrate: value.targetBitrate)
            },
            onDisplayCatalog: { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleViewerDisplayCatalog(
                        event, coreGeneration: coreGeneration, attemptID: attemptID,
                        metrics: metrics, recovery: recovery)
                }
            },
            onDisplaySelection: { [weak self] event in
                DispatchQueue.main.async {
                    self?.handleViewerDisplaySelection(
                        event, coreGeneration: coreGeneration, attemptID: attemptID)
                }
            },
            onClipboardText: { [weak self] text in
                DispatchQueue.main.async {
                    self?.handleViewerClipboardText(
                        text, coreGeneration: coreGeneration, attemptID: attemptID,
                        clipboardSessionEpoch: clipboardSessionEpoch)
                }
            },
            onClipboardRichText: { [weak self] payload in
                DispatchQueue.main.async {
                    self?.handleViewerClipboardRichText(
                        payload, coreGeneration: coreGeneration, attemptID: attemptID,
                        clipboardSessionEpoch: clipboardSessionEpoch)
                }
            },
            onClipboardImage: { [weak self] payload in
                DispatchQueue.main.async {
                    self?.handleViewerClipboardImage(
                        payload, coreGeneration: coreGeneration, attemptID: attemptID,
                        clipboardSessionEpoch: clipboardSessionEpoch)
                }
            })
        try client.connect(configuration)
        let previousClient = coreClient
        coreClient = client
        recovery.attach(client)
        previousClient?.disconnect()
        print(
            "CORE_LOADED abi=\(RustDeskCoreClient.abiVersion) upstream=\(client.upstreamCommit) password_source=environment-or-interactive"
        )
    }

    func handleViewerDisplayCatalog(
        _ event: CoreDisplayCatalogEvent, coreGeneration: UInt64, attemptID: UUID?,
        metrics: PipelineMetrics, recovery: CoreRecoveryCoordinator
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }
        let accepted = viewerDisplaySelectionInputOwner?.observeCatalog(event) == true
        refreshViewerDisplaySelection(chrome: viewerChrome)
        guard accepted, event.status == .available, let selectedDisplay = event.selectedDisplayIndex
        else { return }

        // Core deliberately withholds video until the revisioned display
        // catalog is authoritative. The Host's transport-opening IDR may have
        // arrived during that short fail-closed interval, so request one fresh
        // IDR for each accepted catalog transition instead of waiting for the
        // encoder's periodic keyframe interval.
        Self.requestRecoveryKeyframe(
            display: selectedDisplay, reason: "display-catalog-ready-\(event.catalogRevision)",
            metrics: metrics, recovery: recovery)
    }

    func handleViewerRemotePermission(
        _ event: CoreRemotePermissionEvent, coreGeneration: UInt64, attemptID: UUID?
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }
        guard viewerAudioSessionOwner?.observe(event) == true else { return }
        refreshViewerAudioSession(chrome: viewerChrome)
    }

    func refreshViewerAudioSession(chrome: ViewerChromeView?) {
        guard let snapshot = viewerAudioSessionOwner?.snapshot() else { return }
        chrome?.updateAudioSession(ViewerAudioSessionPresentationPolicy.project(snapshot))
    }

    func handleViewerDisplaySelection(
        _ event: CoreDisplaySelectionEvent, coreGeneration: UInt64, attemptID: UUID?
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }
        _ = viewerDisplaySelectionInputOwner?.observeSelection(event)
        refreshViewerDisplaySelection(chrome: viewerChrome)
    }

    @discardableResult func selectViewerDisplay(displayIndex: UInt32)
        -> ViewerDisplaySelectionInputResult
    {
        let result =
            viewerDisplaySelectionInputOwner?.select(displayIndex: displayIndex)
            ?? .catalogUnavailable
        refreshViewerDisplaySelection(chrome: viewerChrome)
        return result
    }

    func refreshViewerDisplaySelection(chrome: ViewerChromeView?) {
        guard let snapshot = viewerDisplaySelectionInputOwner?.snapshot() else { return }
        chrome?.updateDisplaySelection(ViewerDisplaySelectionPresentationPolicy.project(snapshot))
    }
}
