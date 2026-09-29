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
    func handleViewerCoreState(
        _ event: CoreStateEvent, coreGeneration: UInt64, metrics: PipelineMetrics,
        chrome: ViewerChromeView?, keyboardController: ExclusiveKeyboardController?,
        attemptID: UUID?, evidenceSessionEpoch: UInt64?
    ) {
        guard coreGeneration == viewerCoreGeneration else { return }
        if let attemptID, activeAttemptID != attemptID { return }

        metrics.recordCoreState("\(event.state):\(event.code)")
        print("CORE_STATE state=\(event.state) code=\(event.code)")
        chrome?.updateState(
            Self.connectionStateText(event), isError: Self.isErrorState(event.state))

        if event.state == .authenticated, let attemptID {
            handleAuthenticated(attemptID: attemptID)
        }
        if event.state == .controlReady {
            chrome?.setKeyboardGrabAvailable(true)
            viewerDisplaySelectionInputOwner?.setControlAvailable(true)
            refreshViewerDisplaySelection(chrome: chrome)
        } else if Self.isTerminalState(event.state) {
            viewerAudioSessionOwner?.stop()
            refreshViewerAudioSession(chrome: chrome)
            chrome?.setKeyboardGrabAvailable(false)
            viewerDisplaySelectionInputOwner?.setControlAvailable(false)
            refreshViewerDisplaySelection(chrome: chrome)
            keyboardController?.disable(message: "连接状态变化，已退出键盘独占", isError: false)
        }
        if event.state == .streaming {
            chrome?.setFileTransferAvailable(!viewerFileTransferActionConsumed)
            if viewerOpenFileTransferUploadWhenStreaming {
                viewerOpenFileTransferUploadWhenStreaming = false
                DispatchQueue.main.async { [weak self] in
                    self?.handleViewerFileTransferUploadAction()
                }
            }
        } else if Self.isTerminalState(event.state) {
            chrome?.setFileTransferAvailable(false)
        }

        if event.state == .authenticated || event.state == .streaming {
            if let clipboardSessionEpoch = viewerClipboardSessionEpoch {
                viewerPasteboardOwner.activate(sessionEpoch: clipboardSessionEpoch)
            }
        }

        if event.state == .streaming {
            if let recoverySessionEpoch = viewerRecoverySessionEpoch {
                _ = viewerAutomaticRecoveryOwner?.observeStreaming(
                    sessionEpoch: recoverySessionEpoch)
            }
            if let evidenceSessionEpoch {
                let viewerStreamingRecorded =
                    hostViewerConcurrencyEvidenceOwner.observeViewerStreaming(
                        sessionEpoch: evidenceSessionEpoch)
                if viewerStreamingRecorded { reaffirmHostAgentApplicationConcurrencyEvidence() }
            }
            return
        }

        guard Self.isTerminalState(event.state) else { return }
        if let clipboardSessionEpoch = viewerClipboardSessionEpoch {
            viewerPasteboardOwner.suspend(sessionEpoch: clipboardSessionEpoch)
        }
        if let evidenceSessionEpoch {
            _ = hostViewerConcurrencyEvidenceOwner.observeViewerTerminal(
                sessionEpoch: evidenceSessionEpoch)
        }
        if automatedRun {
            NSApplication.shared.terminate(nil)
            return
        }
        guard viewerChrome != nil, let attemptID else { return }

        if event.state == .passwordRequired || event.state == .authenticationFailed {
            stopViewerAutomaticRecovery()
            handleTerminalState(event, attemptID: attemptID)
            return
        }

        if !ViewerAutomaticRecoveryPolicy.permitsRecovery(after: event) {
            stopViewerAutomaticRecovery()
            handleTerminalState(event, attemptID: attemptID)
            return
        }

        let decision =
            viewerRecoverySessionEpoch.map {
                viewerAutomaticRecoveryOwner?.observeTerminal(sessionEpoch: $0) ?? .finish
            } ?? .finish
        switch decision {
        case .recovering, .ignored: chrome?.updateState("连接中断，正在自动重连…", isError: false)
        case .finish: handleTerminalState(event, attemptID: attemptID)
        }
    }

    func attemptViewerAutomaticRecovery(
        sessionEpoch: UInt64, coreURL: URL, metrics: PipelineMetrics, viewer: ViewerMetalView,
        chrome: ViewerChromeView, decoder: LiveHEVCDecoder, recovery: CoreRecoveryCoordinator,
        attemptID: UUID, evidenceSessionEpoch: UInt64?
    ) -> ViewerAutomaticRecoveryAttemptResult {
        guard activeAttemptID == attemptID, viewerRecoverySessionEpoch == sessionEpoch,
            let deviceID = viewerRecoveryDeviceID, let device = catalog.device(id: deviceID),
            let server = catalog.server, server.isComplete
        else { return .unavailable }

        var password: String
        do {
            guard let storedPassword = try credentialStore.read(deviceID: deviceID),
                !storedPassword.isEmpty
            else { return .unavailable }
            password = storedPassword
        } catch { return .unavailable }
        let configuration = CoreConnectionConfig(
            rendezvousServer: server.rendezvousServer, serverPublicKey: server.serverPublicKey,
            peerID: device.peerID, password: password, forceRelay: server.forceRelay,
            receiveAudio: viewerSessionReceiveAudio, receiveClipboardText: true,
            sendClipboardText: true, receiveClipboardRichText: true, sendClipboardRichText: true,
            receiveClipboardImage: true, sendClipboardImage: true)
        defer { password = "" }

        coreClient?.disconnect()
        coreClient = nil
        decoder.invalidate()
        do {
            try installViewerCoreClient(
                coreURL: coreURL, configuration: configuration, metrics: metrics, viewer: viewer,
                chrome: chrome, decoder: decoder, recovery: recovery, attemptID: attemptID,
                evidenceSessionEpoch: evidenceSessionEpoch)
            chrome.updateState("正在重新建立安全连接…", isError: false)
            return .started
        } catch { return .retryableFailure }
    }

    func handleViewerAutomaticRecoveryExhausted(sessionEpoch: UInt64, attemptID: UUID) {
        guard activeAttemptID == attemptID, viewerRecoverySessionEpoch == sessionEpoch else {
            return
        }
        activeAttemptID = nil
        showHomeUI(error: "连接已断开，自动重连未成功。未保存密码的连接需要重新输入密码。")
    }

    func nextViewerRecoverySessionEpoch() -> UInt64? {
        guard viewerRecoveryCommittedEpoch < UInt64.max else { return nil }
        viewerRecoveryCommittedEpoch += 1
        return viewerRecoveryCommittedEpoch
    }
}
