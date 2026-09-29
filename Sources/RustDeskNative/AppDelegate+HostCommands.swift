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
    @discardableResult func dispatchHostHomeCommand(_ request: HostAgentHomeCommandRequest) -> Bool
    {
        guard Thread.isMainThread else { return false }
        return MainActorBackport.assumeIsolated { dispatchHostHomeCommandOnMain(request) }
    }

    @MainActor func dispatchHostHomeCommandOnMain(_ request: HostAgentHomeCommandRequest) -> Bool {
        refreshHostAgentRuntimeConfigurationCoherence()
        projectHostAgentBackgroundCommandPresentation(
            hostAgentBackgroundCommandPresentationOwner.snapshot())
        let usesLegacyHost =
            hostAgentBackgroundRegistrationStatus == .notRegistered
            && hostAgentBackgroundFlow == nil
        let owner: HostAgentHomeCommandOwner
        if usesLegacyHost {
            owner = .legacy
        } else if hostAgentBackgroundFlow == nil, hostAgentBackgroundRegistrationStatus == .enabled
        {
            owner = .background
        } else {
            owner = .unavailable
        }

        let backgroundSnapshot = HostAgentBackgroundHomeSnapshotProjectionPolicy.presentation(
            phase: coherentHostAgentBackgroundActivationView?.phase,
            projection: coherentHostAgentBackgroundActivationView?.projection)
        let approval =
            usesLegacyHost
            ? hostApprovalHomeSnapshot()
            : backgroundHostApprovalHomeSnapshot(
                backgroundSnapshot, command: hostAgentBackgroundCommandPresentation)
        let session =
            usesLegacyHost
            ? hostActiveSessionHomeSnapshot()
            : backgroundHostActiveSessionHomeSnapshot(
                backgroundSnapshot, command: hostAgentBackgroundCommandPresentation)
        let visibleTargets = HostAgentHomeCommandVisibleTargets(
            approvalConnectionID: approval?.connectionID,
            sessionConnectionID: session?.connectionID,
            enabledActions: enabledHostHomeCommandActions(
                approval: approval, session: session,
                retryAction: hostAgentBackgroundCommandPresentation.retryAction))
        let commandView =
            owner == .background ? hostAgentBackgroundCommandPresentationOwner.snapshot() : nil
        let route = HostAgentHomeCommandRoutingPolicy.route(
            request: request, owner: owner, visibleTargets: visibleTargets,
            legacyCommandsAvailable: usesLegacyHost && hostRuntimeActive,
            phase: coherentHostAgentBackgroundActivationView?.phase,
            projection: coherentHostAgentBackgroundActivationView?.projection,
            commandView: commandView)
        return HostAgentHomeCommandDispatchPolicy.dispatch(
            route: route,
            performLegacy: { [weak self] action, connectionID in
                self?.performLegacyHostHomeCommand(action: action, connectionID: connectionID)
                    ?? false
            },
            submitBackground: { [weak self] action in
                self?.hostAgentBackgroundCommandPresentationOwner.submit(action) ?? false
            },
            retryBackground: { [weak self] action in
                guard let self,
                    self.hostAgentBackgroundCommandPresentationOwner.snapshot().command.activeAction
                        == action
                else { return false }
                return self.hostAgentBackgroundCommandPresentationOwner.retry()
            })
    }

    func projectHostAgentBackgroundCommandPresentation(
        _ view: HostAgentBackgroundHomeCommandPresentationView
    ) {
        hostAgentBackgroundCommandPresentation =
            HostAgentBackgroundHomeCommandReadOnlyPresentationPolicy.presentation(
                view, phase: coherentHostAgentBackgroundActivationView?.phase,
                projection: coherentHostAgentBackgroundActivationView?.projection)
    }

    func performLegacyHostHomeCommand(
        action: HostAgentBackgroundHomeCommandAction, connectionID: String
    ) -> Bool {
        switch action {
        case .approveIncoming:
            return resolveLegacyHostApproval(connectionID: connectionID, decision: .approve)
        case .rejectIncoming:
            return resolveLegacyHostApproval(connectionID: connectionID, decision: .reject)
        case .disableKeyboardAndMouse:
            return performLegacyHostSessionAction(
                connectionID: connectionID, action: .disableKeyboardAndMouse)
        case .disableClipboardRead:
            return performLegacyHostSessionAction(
                connectionID: connectionID, action: .disableClipboardRead)
        case .disableClipboardWrite:
            return performLegacyHostSessionAction(
                connectionID: connectionID, action: .disableClipboardWrite)
        case .disableClipboard:
            return performLegacyHostSessionAction(
                connectionID: connectionID, action: .disableClipboard)
        case .disableSystemAudio:
            return performLegacyHostSessionAction(
                connectionID: connectionID, action: .disableSystemAudio)
        case .disconnect:
            return performLegacyHostSessionAction(connectionID: connectionID, action: .disconnect)
        }
    }

    @discardableResult func resolveLegacyHostApproval(
        connectionID: String, decision: HostApprovalDecision
    ) -> Bool {
        guard hostRuntimeActive, let hostClient,
            hostSnapshot?.pendingApproval?.connectionId == connectionID,
            hostApprovalDecisionGate.beginDecision(connectionID: connectionID)
        else { return false }

        hostStatusText = "正在处理连接请求…"
        hostErrorText = ""
        refreshHomeUI()
        var decisionErrorText: String?
        var decisionCanBeRetried = false
        do {
            try hostClient.resolvePendingApproval(connectionID: connectionID, decision: decision)
        } catch let error as HostControlError {
            switch error.approvalDecisionFailure {
            case .notFound, .alreadyFinalized: decisionErrorText = "连接请求已经结束。"
            case .expired: decisionErrorText = "连接请求已超时并被拒绝。"
            case nil:
                decisionErrorText = sanitizedHostError(error)
                decisionCanBeRetried = true
            }
        } catch {
            decisionErrorText = sanitizedHostError(error)
            decisionCanBeRetried = true
        }
        let snapshotRefreshed = refreshHostSnapshot()
        if decisionCanBeRetried, snapshotRefreshed,
            hostSnapshot?.pendingApproval?.connectionId == connectionID
        {
            hostApprovalDecisionGate.completeDecision(connectionID: connectionID)
        }
        if let decisionErrorText {
            hostErrorText = decisionErrorText
            refreshHomeUI()
        }
        return true
    }

    @discardableResult func performLegacyHostSessionAction(
        connectionID: String, action: HostSessionHomeAction
    ) -> Bool {
        guard hostRuntimeActive, let hostClient,
            hostSnapshot?.activeSession?.connectionId == connectionID
        else { return false }

        let intent: HostSessionCommandIntent
        switch action {
        case .disableKeyboardAndMouse: intent = .disable(.keyboardAndMouse)
        case .disableClipboardRead: intent = .disable(.clipboardRead)
        case .disableClipboardWrite: intent = .disable(.clipboardWrite)
        case .disableClipboard: intent = .disable(.clipboard)
        case .disableSystemAudio: intent = .disable(.systemAudio)
        case .disconnect: intent = .disconnect
        }
        guard hostSessionCommandGate.begin(connectionID: connectionID, intent: intent) else {
            return false
        }

        hostErrorText = ""
        syncHostSessionStatusItem()
        refreshHomeUI()
        var actionErrorText: String?
        do {
            switch intent {
            case .disable(let capability):
                try hostClient.disableActiveSessionCapability(
                    capability, connectionID: connectionID)
            case .disconnect: try hostClient.disconnectSession(connectionID: connectionID)
            }
        } catch let error as HostControlError {
            switch error.sessionCommandFailure {
            case .notFound: actionErrorText = "远程会话已经结束。"
            case .staleConnection: actionErrorText = "远程会话已更新，请按当前状态重试。"
            case .unavailable: actionErrorText = "当前会话暂时无法接收本机控制操作。"
            case nil: actionErrorText = sanitizedHostError(error)
            }
        } catch { actionErrorText = sanitizedHostError(error) }

        refreshHostSnapshot()
        if let actionErrorText {
            hostSessionCommandGate.complete(connectionID: connectionID, intent: intent)
            hostErrorText = actionErrorText
            syncHostSessionStatusItem()
            refreshHomeUI()
        }
        return true
    }

    func syncHostSessionStatusItem() {
        guard let session = hostSnapshot?.activeSession,
            let presentation = HostSessionIndicatorPolicy.presentation(
                connectionID: session.connectionId, remoteID: session.remoteId,
                remoteName: session.remoteName,
                activeAquaSessionAvailable: hostActiveAquaSessionAvailable == true,
                inputAvailability: session.inputAvailability,
                inputUnavailableReason: session.inputUnavailableReason,
                disconnectInFlight: hostSessionCommandGate.resolvingIntent(
                    connectionID: session.connectionId) == .disconnect)
        else {
            removeHostSessionStatusItem()
            return
        }

        if hostSessionStatusItem != nil, hostSessionIndicatorPresentation == presentation { return }
        hostSessionIndicatorPresentation = presentation

        let statusItem =
            hostSessionStatusItem
            ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        hostSessionStatusItem = statusItem
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "display", accessibilityDescription: presentation.title)
            button.image?.isTemplate = true
            button.toolTip = presentation.title
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let titleItem = NSMenuItem(title: presentation.title, action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let identityItem = NSMenuItem(
            title: presentation.remoteIdentityText, action: nil, keyEquivalent: "")
        identityItem.isEnabled = false
        menu.addItem(identityItem)
        menu.addItem(.separator())

        let openItem = NSMenuItem(
            title: "打开 FarPane", action: #selector(openFarPaneFromStatusItem(_:)), keyEquivalent: ""
        )
        openItem.target = self
        openItem.isEnabled = true
        menu.addItem(openItem)

        let disconnectItem = NSMenuItem(
            title: presentation.disconnectTitle,
            action: #selector(disconnectHostSessionFromStatusItem(_:)), keyEquivalent: "")
        disconnectItem.target = self
        disconnectItem.representedObject = presentation.connectionID
        disconnectItem.isEnabled = presentation.disconnectEnabled
        menu.addItem(disconnectItem)
        statusItem.menu = menu
    }

    func removeHostSessionStatusItem() {
        hostSessionIndicatorPresentation = nil
        guard let statusItem = hostSessionStatusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        hostSessionStatusItem = nil
    }

    @objc func openFarPaneFromStatusItem(_ sender: NSMenuItem) { bringMainWindowForward() }

    @objc func disconnectHostSessionFromStatusItem(_ sender: NSMenuItem) {
        guard let connectionID = sender.representedObject as? String else { return }
        _ = performLegacyHostSessionAction(connectionID: connectionID, action: .disconnect)
    }
}
