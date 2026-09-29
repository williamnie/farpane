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
    func hostApprovalHomeSnapshot() -> HostApprovalHomeSnapshot? {
        guard let pending = hostSnapshot?.pendingApproval else { return nil }
        guard let capabilityNames = hostCapabilityNames(pending.requestedCapabilities),
            let transportText = hostTransportText(pending.transport)
        else { return nil }

        return HostApprovalHomeSnapshot(
            connectionID: pending.connectionId,
            remoteIdentityText: hostClaimedIdentityText(
                remoteID: pending.remoteId, remoteName: pending.remoteName),
            contextText:
                "\(hostPlatformText(pending.remotePlatform)) · \(transportText) · 每次均需本机批准",
            capabilityText: "请求权限：\(capabilityNames.joined(separator: "、"))",
            expiryText: hostApprovalExpiryText(expiresAt: pending.expiresAt),
            isResolving: hostApprovalDecisionGate.isResolving(connectionID: pending.connectionId),
            enabledActions: [.approve, .reject])
    }

    func hostActiveSessionHomeSnapshot() -> HostActiveSessionHomeSnapshot? {
        guard let session = hostSnapshot?.activeSession else { return nil }
        let activeCapabilities = Set(session.activeCapabilities)
        guard let capabilityNames = hostCapabilityNames(session.activeCapabilities) else {
            return nil
        }
        let startedAt = Date(timeIntervalSince1970: TimeInterval(session.startedAt) / 1_000)
        let startedText = DateFormatter.localizedString(
            from: startedAt, dateStyle: .none, timeStyle: .short)
        let pendingAction: HostSessionHomeAction?
        switch hostSessionCommandGate.resolvingIntent(connectionID: session.connectionId) {
        case .disable(.keyboardAndMouse): pendingAction = .disableKeyboardAndMouse
        case .disable(.clipboardRead): pendingAction = .disableClipboardRead
        case .disable(.clipboardWrite): pendingAction = .disableClipboardWrite
        case .disable(.clipboard): pendingAction = .disableClipboard
        case .disable(.systemAudio): pendingAction = .disableSystemAudio
        case .disconnect: pendingAction = .disconnect
        case nil: pendingAction = nil
        }
        guard
            let sessionPresentation = HostSessionPresentationPolicy.presentation(
                activeAquaSessionAvailable: hostActiveAquaSessionAvailable == true,
                inputAvailability: session.inputAvailability,
                inputUnavailableReason: session.inputUnavailableReason)
        else { return nil }
        let capabilityText = [
            "当前权限：\(capabilityNames.joined(separator: "、"))", sessionPresentation.detailText,
        ].compactMap { $0 }.joined(separator: "；")
        var enabledActions: Set<HostSessionHomeAction> = [.disconnect]
        if activeCapabilities.contains("controlKeyboardMouse") {
            enabledActions.insert(.disableKeyboardAndMouse)
        }
        if activeCapabilities.contains("readClipboard") {
            enabledActions.insert(.disableClipboardRead)
        }
        if activeCapabilities.contains("writeClipboard") {
            enabledActions.insert(.disableClipboardWrite)
        }
        if activeCapabilities.contains("hearSystemAudio") {
            enabledActions.insert(.disableSystemAudio)
        }

        return HostActiveSessionHomeSnapshot(
            connectionID: session.connectionId,
            remoteIdentityText: hostClaimedIdentityText(
                remoteID: session.remoteId, remoteName: session.remoteName),
            contextText: "\(hostPlatformText(session.remotePlatform)) · \(startedText) 开始连接",
            capabilityText: capabilityText,
            canDisableKeyboardAndMouse: activeCapabilities.contains("controlKeyboardMouse"),
            canDisableClipboardRead: activeCapabilities.contains("readClipboard"),
            canDisableClipboardWrite: activeCapabilities.contains("writeClipboard"),
            canDisableClipboard: activeCapabilities.contains("readClipboard")
                && activeCapabilities.contains("writeClipboard"),
            canDisableSystemAudio: activeCapabilities.contains("hearSystemAudio"),
            pendingAction: pendingAction, enabledActions: enabledActions)
    }

    func backgroundHostApprovalHomeSnapshot(
        _ backgroundSnapshot: HostAgentBackgroundHomeSnapshotPresentation,
        command: HostAgentBackgroundHomeCommandReadOnlyPresentation
    ) -> HostApprovalHomeSnapshot? {
        guard let pending = backgroundSnapshot.pendingApproval,
            let capabilityNames = hostCapabilityNames(pending.requestedCapabilities),
            let transportText = hostTransportText(pending.transport)
        else { return nil }
        let availableActions = Set(command.availableActions)
        var enabledActions: Set<HostApprovalHomeAction> = []
        if availableActions.contains(.approveIncoming) { enabledActions.insert(.approve) }
        if availableActions.contains(.rejectIncoming) { enabledActions.insert(.reject) }
        return HostApprovalHomeSnapshot(
            connectionID: pending.connectionID,
            remoteIdentityText: hostClaimedIdentityText(
                remoteID: pending.remoteID, remoteName: pending.remoteName),
            contextText:
                "\(hostPlatformText(pending.remotePlatform)) · \(transportText) · 每次均需本机批准",
            capabilityText: "请求权限：\(capabilityNames.joined(separator: "、"))",
            expiryText: backgroundHostApprovalExpiryText(expiresAt: pending.expiresAt),
            isResolving: command.activeAction == .approveIncoming
                || command.activeAction == .rejectIncoming, enabledActions: enabledActions)
    }

    func backgroundHostActiveSessionHomeSnapshot(
        _ backgroundSnapshot: HostAgentBackgroundHomeSnapshotPresentation,
        command: HostAgentBackgroundHomeCommandReadOnlyPresentation
    ) -> HostActiveSessionHomeSnapshot? {
        guard let session = backgroundSnapshot.activeSession,
            let capabilityNames = hostCapabilityNames(session.activeCapabilities),
            let sessionPresentation = backgroundSnapshot.activeSessionPresentation
        else { return nil }
        let activeCapabilities = Set(session.activeCapabilities)
        let startedAt = Date(timeIntervalSince1970: TimeInterval(session.startedAt) / 1_000)
        let startedText = DateFormatter.localizedString(
            from: startedAt, dateStyle: .none, timeStyle: .short)
        let capabilityText = [
            "当前权限：\(capabilityNames.joined(separator: "、"))", sessionPresentation.detailText,
        ].compactMap { $0 }.joined(separator: "；")
        let availableActions = Set(command.availableActions)
        var enabledActions: Set<HostSessionHomeAction> = []
        if availableActions.contains(.disableKeyboardAndMouse) {
            enabledActions.insert(.disableKeyboardAndMouse)
        }
        if availableActions.contains(.disableClipboardRead) {
            enabledActions.insert(.disableClipboardRead)
        }
        if availableActions.contains(.disableClipboardWrite) {
            enabledActions.insert(.disableClipboardWrite)
        }
        if availableActions.contains(.disableClipboard) { enabledActions.insert(.disableClipboard) }
        if availableActions.contains(.disableSystemAudio) {
            enabledActions.insert(.disableSystemAudio)
        }
        if availableActions.contains(.disconnect) { enabledActions.insert(.disconnect) }
        return HostActiveSessionHomeSnapshot(
            connectionID: session.connectionID,
            remoteIdentityText: hostClaimedIdentityText(
                remoteID: session.remoteID, remoteName: session.remoteName),
            contextText: "\(hostPlatformText(session.remotePlatform)) · \(startedText) 开始连接",
            capabilityText: capabilityText,
            canDisableKeyboardAndMouse: backgroundSnapshot.allowsSessionMutationCommands
                && activeCapabilities.contains("controlKeyboardMouse"),
            canDisableClipboardRead: backgroundSnapshot.allowsSessionMutationCommands
                && activeCapabilities.contains("readClipboard"),
            canDisableClipboardWrite: backgroundSnapshot.allowsSessionMutationCommands
                && activeCapabilities.contains("writeClipboard"),
            canDisableClipboard: backgroundSnapshot.allowsSessionMutationCommands
                && activeCapabilities.contains("readClipboard")
                && activeCapabilities.contains("writeClipboard"),
            canDisableSystemAudio: backgroundSnapshot.allowsSessionMutationCommands
                && activeCapabilities.contains("hearSystemAudio"),
            pendingAction: backgroundHostSessionAction(command.activeAction),
            enabledActions: enabledActions)
    }

    func backgroundHostCommandRetryHomeSnapshot(
        command: HostAgentBackgroundHomeCommandReadOnlyPresentation,
        approval: HostApprovalHomeSnapshot?, session: HostActiveSessionHomeSnapshot?
    ) -> HostCommandRetryHomeSnapshot? {
        guard command.canRetry, let action = command.retryAction else { return nil }
        guard
            let connectionID = action.targetsApproval
                ? approval?.connectionID : session?.connectionID
        else { return nil }
        return HostCommandRetryHomeSnapshot(connectionID: connectionID, title: "重试" + action.title)
    }

    func backgroundHostSessionAction(_ action: HostAgentBackgroundHomeCommandAction?)
        -> HostSessionHomeAction?
    {
        switch action {
        case .disableKeyboardAndMouse: return .disableKeyboardAndMouse
        case .disableClipboardRead: return .disableClipboardRead
        case .disableClipboardWrite: return .disableClipboardWrite
        case .disableClipboard: return .disableClipboard
        case .disableSystemAudio: return .disableSystemAudio
        case .disconnect: return .disconnect
        case .approveIncoming, .rejectIncoming, nil: return nil
        }
    }

    func hostAgentCommandAction(for action: HostSessionHomeAction)
        -> HostAgentBackgroundHomeCommandAction
    {
        switch action {
        case .disableKeyboardAndMouse: return .disableKeyboardAndMouse
        case .disableClipboardRead: return .disableClipboardRead
        case .disableClipboardWrite: return .disableClipboardWrite
        case .disableClipboard: return .disableClipboard
        case .disableSystemAudio: return .disableSystemAudio
        case .disconnect: return .disconnect
        }
    }

    func enabledHostHomeCommandActions(
        approval: HostApprovalHomeSnapshot?, session: HostActiveSessionHomeSnapshot?,
        retryAction: HostAgentBackgroundHomeCommandAction? = nil
    ) -> [HostAgentBackgroundHomeCommandAction] {
        var actions: [HostAgentBackgroundHomeCommandAction] = []
        if let approval, !approval.isResolving {
            if approval.enabledActions.contains(.approve) { actions.append(.approveIncoming) }
            if approval.enabledActions.contains(.reject) { actions.append(.rejectIncoming) }
        }
        if let session, session.pendingAction == nil {
            let sessionActions: [HostSessionHomeAction] = [
                .disableKeyboardAndMouse, .disableClipboardRead, .disableClipboardWrite,
                .disableClipboard, .disableSystemAudio, .disconnect,
            ]
            actions += sessionActions.filter(session.enabledActions.contains).map(
                hostAgentCommandAction)

        }
        if let retryAction {
            let targetIsVisible = retryAction.targetsApproval ? approval != nil : session != nil
            if targetIsVisible, !actions.contains(retryAction) { actions.append(retryAction) }
        }
        return actions
    }

    func hostCapabilityNames(_ capabilities: [String]) -> [String]? {
        let names = capabilities.compactMap { capability -> String? in
            switch capability {
            case "viewDisplay": return "查看屏幕"
            case "controlKeyboardMouse": return "控制键盘与鼠标"
            case "readClipboard": return "读取剪贴板"
            case "writeClipboard": return "写入剪贴板"
            case "hearSystemAudio": return "收听系统音频"
            default: return nil
            }
        }
        return names.count == capabilities.count ? names : nil
    }

    func hostClaimedIdentityText(remoteID: String, remoteName: String) -> String {
        remoteName.isEmpty ? "对方声明（未经验证）：\(remoteID)" : "对方声明（未经验证）：\(remoteName) · ID \(remoteID)"
    }

    func hostPlatformText(_ platform: String) -> String { platform.isEmpty ? "未知平台" : platform }

    func hostTransportText(_ transport: String) -> String? {
        switch transport {
        case "direct": return "直连"
        case "relay": return "中继"
        case "unknown": return "连接方式尚未确认"
        default: return nil
        }
    }

    func hostApprovalExpiryText(expiresAt: UInt64) -> String {
        let nowMilliseconds = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        let remainingMilliseconds = expiresAt > nowMilliseconds ? expiresAt - nowMilliseconds : 0
        let remainingSeconds =
            remainingMilliseconds / 1_000 + (remainingMilliseconds.isMultiple(of: 1_000) ? 0 : 1)
        return remainingSeconds == 0 ? "正在自动拒绝已超时请求" : "约 \(remainingSeconds) 秒后自动拒绝"
    }

    func backgroundHostApprovalExpiryText(expiresAt: UInt64) -> String {
        let expiry = Date(timeIntervalSince1970: TimeInterval(expiresAt) / 1_000)
        let text = DateFormatter.localizedString(from: expiry, dateStyle: .none, timeStyle: .medium)
        return "后台自动拒绝时间：\(text)"
    }

    func requestAttentionForPendingHostApproval() {
        NSApplication.shared.requestUserAttention(.criticalRequest)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
