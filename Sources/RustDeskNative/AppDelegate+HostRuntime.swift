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
    func startHostMode() {
        guard !hostRuntimeActive else { return }
        guard hostRuntimeQuiescenceConfirmed else {
            hostStatusText = "停止状态待确认"
            hostErrorText = "无法确认旧的被控端已停止；请重新启动 FarPane 后重试。"
            return
        }
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
        hostActiveAquaSessionAvailable = nil
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
                let created = try HostControlClient(libraryURL: coreURL, eventQueue: .main) {
                    [weak self] event in self?.handleHostCoreEvent(event)
                }
                try created.setConfigRoot(appName: "FarPaneHost", org: "io.rustdesknative")
                hostClient = created
                client = created
            }
            let clipboardPolicy = currentHostClipboardPolicy()
            let fileTransferPolicy = currentHostFileTransferPolicy()
            let audioPolicy = currentHostAudioPolicy()
            try client.start(
                configuration: HostServerConfiguration(
                    rendezvousServer: server.rendezvousServer,
                    serverPublicKey: server.serverPublicKey,
                    clipboardReadEnabled: clipboardPolicy.allowRemoteRead,
                    clipboardWriteEnabled: clipboardPolicy.allowRemoteWrite,
                    clipboardRichTextReadEnabled: clipboardPolicy.allowRemoteRichTextRead,
                    clipboardRichTextWriteEnabled: clipboardPolicy.allowRemoteRichTextWrite,
                    clipboardImageReadEnabled: clipboardPolicy.allowRemoteImageRead,
                    clipboardImageWriteEnabled: clipboardPolicy.allowRemoteImageWrite,
                    audioEnabled: audioPolicy.enabled,
                    audioInputDeviceName: audioPolicy.inputDeviceName,
                    fileTransferEnabled: fileTransferPolicy.enabled,
                    fileTransferReceiveRoot: fileTransferPolicy.receiveRoot))
            hostRuntimeActive = true
            hostRuntimeQuiescenceConfirmed = true
            refreshHostSnapshot()
            hostPollTimer?.invalidate()
            hostPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] _ in self?.refreshHostSnapshot()
            }
        } catch {
            hostRuntimeActive = false
            hostSnapshot = nil
            hostActiveAquaSessionAvailable = nil
            hostStatusText = "启动失败"
            hostErrorText = sanitizedHostError(error)
            recordHostRuntimeStateEvidence(force: true)
        }
    }

    @discardableResult func stopHostMode(
        preservePreference: Bool, reason: HostStopReason, releaseClient: Bool = false
    ) -> Bool {
        hostPollTimer?.invalidate()
        hostPollTimer = nil
        hostPasswordHideTimer?.invalidate()
        hostPasswordHideTimer = nil
        hostTemporaryPassword = ""
        hostSnapshot = nil
        hostActiveAquaSessionAvailable = nil
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
        var stopSucceeded = hostRuntimeQuiescenceConfirmed
        if hostRuntimeActive, hostRuntimeQuiescenceConfirmed {
            if let hostClient {
                do {
                    try hostClient.stop(reason: reason)
                    stopSucceeded = true
                } catch {
                    stopSucceeded = false
                    hostErrorText = sanitizedHostError(error)
                }
            } else {
                stopSucceeded = false
                hostErrorText = "无法确认被控端已停止；请重新启动 FarPane 后重试。"
            }
        }
        if stopSucceeded {
            hostErrorText = ""
            hostRuntimeActive = false
        }
        hostRuntimeQuiescenceConfirmed = stopSucceeded
        if releaseClient, stopSucceeded { hostClient = nil }
        hostStatusText = stopSucceeded ? (preservePreference ? "远程控制期间已暂停" : "已关闭") : "停止状态待确认"
        recordHostRuntimeStateEvidence(force: true)
        return stopSucceeded
    }

    @discardableResult func refreshHostSnapshot() -> Bool {
        guard hostRuntimeActive, let hostClient else { return false }
        var refreshed = false
        do {
            let snapshot = try hostClient.copySnapshot()
            hostSnapshot = snapshot
            refreshed = true
            let activeAquaSessionAvailable =
                snapshot.activeSession != nil
                && HostActiveAquaSessionAuthority.currentSessionIsAvailable()
            hostActiveAquaSessionAvailable =
                snapshot.activeSession == nil ? nil : activeAquaSessionAvailable
            syncHostMediaCaptureAvailability(
                activeSession: snapshot.activeSession,
                activeAquaSessionAvailable: activeAquaSessionAvailable)
            hostSessionCommandGate.observe(
                connectionID: snapshot.activeSession?.connectionId,
                activeCapabilities: snapshot.activeSession?.activeCapabilities ?? [])
            syncHostSessionStatusItem()
            let shouldRequestAttention = hostApprovalDecisionGate.observe(
                connectionID: snapshot.pendingApproval?.connectionId)
            configureHostMediaCapabilitiesIfNeeded(snapshot: snapshot, client: hostClient)
            if let pending = snapshot.pendingApproval {
                hostStatusText =
                    hostApprovalDecisionGate.isResolving(connectionID: pending.connectionId)
                    ? "正在处理连接请求…" : "等待本机批准…"
            } else if let session = snapshot.activeSession,
                let sessionPresentation = HostSessionPresentationPolicy.presentation(
                    activeAquaSessionAvailable: activeAquaSessionAvailable,
                    inputAvailability: session.inputAvailability,
                    inputUnavailableReason: session.inputUnavailableReason)
            {
                hostStatusText =
                    !activeAquaSessionAvailable || session.inputAvailability == .limited
                    ? sessionPresentation.overallStatusText
                    : (hostMediaStatusText ?? sessionPresentation.overallStatusText)
            } else {
                switch snapshot.registrationStatus {
                case "ready": hostStatusText = hostMediaStatusText ?? "可被连接"
                case "degraded": hostStatusText = "连接异常"
                default: hostStatusText = "正在连接服务器…"
                }
            }
            hostErrorText = snapshot.lastError == nil ? "" : "Host 服务暂时不可用，将继续重试。"
            if shouldRequestAttention { requestAttentionForPendingHostApproval() }
        } catch {
            hostActiveAquaSessionAvailable = hostSnapshot?.activeSession == nil ? nil : false
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
}
