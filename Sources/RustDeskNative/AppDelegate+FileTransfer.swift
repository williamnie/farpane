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
    func prepareViewerFileTransferComposition(coreURL: URL, baseConfiguration: CoreConnectionConfig)
        -> Bool
    {
        stopViewerFileTransfer()
        let verifiedCredentialDeviceID = pendingProductConnection.flatMap {
            $0.usedStoredCredential || $0.savePassword ? $0.deviceID : nil
        }
        let context = ViewerFileTransferConnectionContext(
            baseConfiguration: baseConfiguration, credentialDeviceID: verifiedCredentialDeviceID)
        return installViewerFileTransferComposition(coreURL: coreURL, context: context)
    }

    func installViewerFileTransferComposition(
        coreURL: URL, context: ViewerFileTransferConnectionContext
    ) -> Bool {
        guard let sessionEpoch = nextViewerFileTransferSessionEpoch(),
            let composition = ViewerFileTransferProductComposition(
                sessionEpoch: sessionEpoch,
                makeCore: { callbacks in
                    try RustDeskCoreClient(
                        libraryURL: coreURL, onState: callbacks.onState, onVideo: { _ in },
                        onMetrics: { _ in }, onFileTransferEvent: callbacks.onTransfer,
                        onFileTransferManifest: callbacks.onManifest)
                },
                onEvent: { [weak self] event in
                    DispatchQueue.main.async {
                        self?.handleViewerFileTransferProductEvent(
                            event, sessionEpoch: sessionEpoch)
                    }
                })
        else { return false }
        viewerFileTransferComposition = composition
        viewerFileTransferActionConsumed = false
        viewerFileTransferConnectionContext = context
        viewerFileTransferCoreURL = coreURL
        return true
    }

    func rearmViewerFileTransferComposition() -> Bool {
        guard let coreURL = viewerFileTransferCoreURL,
            let context = viewerFileTransferConnectionContext
        else { return false }
        let previous = viewerFileTransferComposition
        viewerFileTransferComposition = nil
        viewerFileTransferActiveTransferID = nil
        viewerFileTransferActiveDirection = nil
        viewerFileTransferActionConsumed = false
        _ = previous?.teardown()
        return installViewerFileTransferComposition(coreURL: coreURL, context: context)
    }

    func stopViewerFileTransfer() {
        let composition = viewerFileTransferComposition
        let destinationPicker = viewerFileTransferDestinationPicker
        let uploadPicker = viewerFileTransferUploadSourcePicker
        let passwordPrompt = viewerFileTransferPasswordPrompt
        viewerFileTransferComposition = nil
        viewerFileTransferDestinationPicker = nil
        viewerFileTransferUploadSourcePicker = nil
        viewerFileTransferPasswordPrompt = nil
        viewerFileTransferActiveTransferID = nil
        viewerFileTransferActiveDirection = nil
        viewerFileTransferActionConsumed = false
        viewerFileTransferConnectionContext = nil
        viewerFileTransferCoreURL = nil
        viewerChrome?.updateFileTransferAction(active: false)
        viewerChrome?.setFileTransferAvailable(false)
        destinationPicker?.cancel()
        uploadPicker?.cancel()
        passwordPrompt?.cancel()
        _ = composition?.teardown()
    }

    func nextViewerFileTransferSessionEpoch() -> UInt64? {
        guard viewerFileTransferCommittedEpoch < UInt64.max else { return nil }
        viewerFileTransferCommittedEpoch += 1
        return viewerFileTransferCommittedEpoch
    }

    func handleViewerFileTransferAction() {
        // Recursive manifest authority is intentionally one-shot per
        // composition; terminal completion rearms a fresh composition.
        guard let composition = viewerFileTransferComposition else { return }
        if let transferID = viewerFileTransferActiveTransferID {
            guard viewerFileTransferActiveDirection == .download else { return }
            guard composition.requestCancellation(transferID: transferID) else {
                viewerChrome?.updateState("当前文件接收尚不能取消", isError: true)
                return
            }
            viewerChrome?.updateState("正在取消文件接收…", isError: false)
            return
        }
        guard !viewerFileTransferActionConsumed else { return }
        guard viewerFileTransferDestinationPicker == nil,
            viewerFileTransferUploadSourcePicker == nil, viewerFileTransferPasswordPrompt == nil,
            let window
        else { return }
        let sessionEpoch = composition.snapshot().sessionEpoch

        let picker = ViewerFileTransferDestinationPickerController()
        viewerFileTransferDestinationPicker = picker
        picker.begin(on: window) { [weak self] destination in
            guard let self else { return }
            self.viewerFileTransferDestinationPicker = nil
            guard let destination,
                self.viewerFileTransferComposition?.snapshot().sessionEpoch == sessionEpoch
            else { return }
            self.resolveViewerFileTransferPassword(
                selection: .download(destinationDirectory: destination), sessionEpoch: sessionEpoch)
        }
    }

    func handleViewerFileTransferUploadAction() {
        guard let composition = viewerFileTransferComposition else { return }
        if let transferID = viewerFileTransferActiveTransferID {
            guard viewerFileTransferActiveDirection == .upload else { return }
            guard composition.requestCancellation(transferID: transferID) else {
                viewerChrome?.updateState("当前文件发送尚不能取消", isError: true)
                return
            }
            viewerChrome?.updateState("正在取消文件发送…", isError: false)
            return
        }
        guard !viewerFileTransferActionConsumed else { return }
        guard viewerFileTransferDestinationPicker == nil,
            viewerFileTransferUploadSourcePicker == nil, viewerFileTransferPasswordPrompt == nil,
            let window
        else { return }
        let sessionEpoch = composition.snapshot().sessionEpoch

        let picker = ViewerFileTransferUploadSourcePickerController()
        viewerFileTransferUploadSourcePicker = picker
        picker.begin(on: window) { [weak self] selectedURLs in
            guard let self else { return }
            self.viewerFileTransferUploadSourcePicker = nil
            guard let selectedURLs,
                self.viewerFileTransferComposition?.snapshot().sessionEpoch == sessionEpoch
            else { return }
            self.resolveViewerFileTransferPassword(
                selection: .upload(selectedURLs: selectedURLs), sessionEpoch: sessionEpoch)
        }
    }

    func resolveViewerFileTransferPassword(
        selection: ViewerFileTransferSelection, sessionEpoch: UInt64
    ) {
        guard let context = viewerFileTransferConnectionContext,
            viewerFileTransferComposition?.snapshot().sessionEpoch == sessionEpoch
        else { return }
        if let deviceID = context.credentialDeviceID {
            do {
                if var password = try credentialStore.read(deviceID: deviceID), !password.isEmpty {
                    startViewerFileTransferAction(
                        selection: selection, password: password, sessionEpoch: sessionEpoch)
                    password = ""
                    return
                }
            } catch {
                // The explicit secure prompt is the fail-closed fallback.
            }
        }
        guard let window, viewerFileTransferPasswordPrompt == nil else { return }
        let prompt = ViewerFileTransferPasswordPromptController()
        viewerFileTransferPasswordPrompt = prompt
        prompt.begin(on: window) { [weak self] suppliedPassword in
            guard let self else { return }
            self.viewerFileTransferPasswordPrompt = nil
            guard var suppliedPassword,
                self.viewerFileTransferComposition?.snapshot().sessionEpoch == sessionEpoch
            else { return }
            self.startViewerFileTransferAction(
                selection: selection, password: suppliedPassword, sessionEpoch: sessionEpoch)
            suppliedPassword = ""
        }
    }

    func startViewerFileTransferAction(
        selection: ViewerFileTransferSelection, password: String, sessionEpoch: UInt64
    ) {
        guard viewerFileTransferActiveTransferID == nil,
            let context = viewerFileTransferConnectionContext,
            let composition = viewerFileTransferComposition,
            composition.snapshot().sessionEpoch == sessionEpoch
        else { return }
        var configuration = context.configuration(password: password)
        let outcome: (transferID: Int32?, direction: ViewerFileTransferActionDirection)
        switch selection {
        case .download(let destinationDirectory):
            let result = composition.requestDownload(
                baseConfiguration: configuration, destinationDirectory: destinationDirectory)
            switch result {
            case .accepted(let transferID): outcome = (transferID, .download)
            case .destinationRejected:
                viewerChrome?.updateState("接收目录必须属于当前用户且权限为 0700", isError: true)
                outcome = (nil, .download)
            case .unavailable:
                viewerFileTransferActionConsumed = true
                viewerChrome?.updateState("文件接收启动失败", isError: true)
                viewerChrome?.setFileTransferAvailable(rearmViewerFileTransferComposition())
                outcome = (nil, .download)
            }
        case .upload(let selectedURLs):
            let result = composition.requestFileTransferUpload(
                baseConfiguration: configuration, selectedURLs: selectedURLs)
            switch result {
            case .accepted(let transferID): outcome = (transferID, .upload)
            case .sourceRejected:
                viewerChrome?.updateState("所选发送内容包含不安全、不可读取或冲突的条目", isError: true)
                outcome = (nil, .upload)
            case .unavailable:
                viewerFileTransferActionConsumed = true
                viewerChrome?.updateState("文件发送启动失败", isError: true)
                viewerChrome?.setFileTransferAvailable(rearmViewerFileTransferComposition())
                outcome = (nil, .upload)
            }
        }
        configuration = context.configuration(password: "")
        _ = configuration
        if let transferID = outcome.transferID {
            viewerFileTransferActionConsumed = true
            viewerFileTransferActiveTransferID = transferID
            viewerFileTransferActiveDirection = outcome.direction
            viewerChrome?.updateFileTransferAction(
                active: true, cancellable: false, direction: outcome.direction)
            viewerChrome?.updateState("正在建立文件传输通道…", isError: false)
        }
    }
}
