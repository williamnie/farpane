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
    func prepareProductCatalog() {
        do {
            let migration = try LegacyProfileMigrator().migrateIfNeeded(to: catalogStore)
            if migration == .invalidLegacyProfilePreserved {
                homeErrorText = "旧连接配置无法读取，原数据已保留；请重新配置服务器。"
            }
            catalog = try catalogStore.load()
            reconcileHostAgentBootstrap()
        } catch {
            catalog = DeviceCatalogDocument()
            catalogMutationBlocked = true
            hostAgentBootstrapState = .degraded
            homeErrorText = "本地设备列表无法读取，原文件已保留。请从服务器设置中确认后重建。"
        }
    }

    func showHomeUI(error: String = "") {
        _ = hostAudioInputDeviceCatalogOwner.refresh()
        let hostReceiveRootPicker = hostFileTransferReceiveRootPicker
        hostFileTransferReceiveRootPicker = nil
        hostReceiveRootPicker?.cancel()
        stopViewerAutomaticRecovery()
        stopViewerClipboard()
        stopViewerFileTransfer()
        viewerOpenFileTransferUploadWhenStreaming = false
        stopViewerDisplaySelectionInput()
        viewerAudioSessionOwner?.stop()
        viewerAudioSessionOwner = nil
        let viewerLifecycleStopped = stopViewerLifecycleEvidence()
        if viewerLifecycleStopped { reaffirmHostAgentApplicationConcurrencyEvidence() }
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
        viewerRecoveryDeviceID = nil
        viewerRecoverySessionEpoch = nil
        viewerCoreGeneration = 0
        viewerAudioOptInForNextConnection = false
        viewerSessionReceiveAudio = false
        keyboardController = nil
        liveDecoder = nil
        renderer = nil
        metrics = nil
        viewerChrome = nil
        viewerView = nil
        pendingProductConnection?.password = ""
        pendingProductConnection = nil
        let frame = NSRect(x: 0, y: 0, width: 1060, height: 720)
        let window =
            self.window
            ?? NSWindow(
                contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = "FarPane"
        window.minSize = NSSize(width: 860, height: 620)
        window.appearance = NSAppearance(named: .darkAqua)
        let view = HomeView()
        view.onQuickConnect = { [weak self] peerID in self?.handleQuickConnect(peerID: peerID) }
        view.onQuickSendFiles = { [weak self] peerID in
            self?.handleQuickConnect(peerID: peerID, opensFileTransferUpload: true)
        }
        view.onViewerAudioOptInToggle = { [weak self] enabled in
            guard let self, self.activeAttemptID == nil else { return }
            self.viewerAudioOptInForNextConnection = enabled
            self.refreshHomeUI()
        }
        view.onOpenServerSettings = { [weak self] in self?.presentServerSettings() }
        view.onDeviceAction = { [weak self] deviceID, action in
            self?.handleDeviceAction(deviceID: deviceID, action: action)
        }
        view.onHostToggle = { [weak self] enabled in self?.handleHostProductToggle(enabled) }
        view.onHostClipboardToggle = { [weak self] preference, enabled in
            self?.handleHostClipboardPolicyToggle(preference, enabled: enabled)
        }
        view.onHostFileTransferToggle = { [weak self] enabled in
            self?.handleHostFileTransferPolicyToggle(enabled)
        }
        view.onChooseHostFileTransferReceiveRoot = { [weak self] in
            self?.beginHostFileTransferReceiveRootSelection()
        }
        view.onHostAudioToggle = { [weak self] enabled in self?.handleHostAudioPolicyToggle(enabled)
        }
        view.onHostAudioInputSelection = { [weak self] name in
            self?.handleHostAudioInputSelection(name)
        }
        view.onRefreshHostAudioInputs = { [weak self] in self?.refreshHostAudioInputs() }
        view.onRevealHostPassword = { [weak self] in self?.revealHostTemporaryPassword() }
        view.onCopyHostTemporaryPassword = { [weak self] in self?.copyHostTemporaryPassword() }
        view.onRegenerateHostPassword = { [weak self] in self?.regenerateHostTemporaryPassword() }
        view.onSetHostPermanentPassword = { [weak self] in self?.presentHostPermanentPassword() }
        view.onClearHostPermanentPassword = { [weak self] in
            self?.confirmClearHostPermanentPassword()
        }
        view.onApproveHostConnection = { [weak self] connectionID in
            _ = self?.dispatchHostHomeCommand(
                .perform(action: .approveIncoming, connectionID: connectionID))
        }
        view.onRejectHostConnection = { [weak self] connectionID in
            _ = self?.dispatchHostHomeCommand(
                .perform(action: .rejectIncoming, connectionID: connectionID))
        }
        view.onHostSessionAction = { [weak self] connectionID, action in
            guard let self else { return }
            _ = self.dispatchHostHomeCommand(
                .perform(
                    action: self.hostAgentCommandAction(for: action), connectionID: connectionID))
        }
        view.onRetryHostCommand = { [weak self] connectionID in
            _ = self?.dispatchHostHomeCommand(.retry(connectionID: connectionID))
        }
        view.onRefreshSystemPermissions = { [weak self] in self?.refreshHomeUI() }
        view.onOpenSystemPermissionSettings = { kind in Self.openSystemPermissionSettings(kind) }
        view.onReadLocalClipboardText = { [weak self] in
            self?.viewerPasteboardOwner.readLocalProductText()
        }
        view.onWriteLocalClipboardText = { [weak self] text in
            self?.viewerPasteboardOwner.writeLocalProductText(text) ?? false
        }
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        self.window = window
        homeView = view
        reconcileHostProductOwnership()
        refreshHomeUI()
        if catalog.server == nil, !catalogMutationBlocked {
            DispatchQueue.main.async { [weak self] in self?.presentServerSettings() }
        } else {
            DispatchQueue.main.async { [weak view] in view?.focusQuickConnect() }
        }
    }

    func refreshHomeUI() {
        guard let homeView else { return }
        refreshHostAgentRuntimeConfigurationCoherence()
        projectHostAgentBackgroundCommandPresentation(
            hostAgentBackgroundCommandPresentationOwner.snapshot())
        var credentialError = false
        let items = catalog.sortedDevices.map { device -> HomeDeviceItem in
            let hasPassword: Bool
            do { hasPassword = try credentialStore.contains(deviceID: device.id) } catch {
                hasPassword = false
                credentialError = true
            }
            return HomeDeviceItem(device: device, hasSavedPassword: hasPassword)
        }
        var error = homeErrorText
        if credentialError, error.isEmpty { error = "部分钥匙串密码暂时无法读取；连接时将要求手动输入。" }
        let legacyAssessment = MainActorBackport.assumeIsolated {
            HostAgentLegacyHostMigrationGate.assess(captureLegacyHostMigrationEvidence())
        }
        let hostControl = HostAgentBackgroundHomeRoutingPolicy.controlState(
            registration: hostAgentBackgroundRegistrationStatus, legacy: legacyAssessment,
            flow: hostAgentBackgroundFlow)
        let hostReadiness = HostAgentBackgroundHomeReadinessPresentationPolicy.presentation(
            phase: coherentHostAgentBackgroundActivationView?.phase,
            registration: hostAgentBackgroundRegistrationStatus)
        let backgroundSnapshot = HostAgentBackgroundHomeSnapshotProjectionPolicy.presentation(
            phase: coherentHostAgentBackgroundActivationView?.phase,
            projection: coherentHostAgentBackgroundActivationView?.projection)
        let usesLegacyHost =
            hostAgentBackgroundRegistrationStatus == .notRegistered
            && hostAgentBackgroundFlow == nil
        let legacyHostIsReady =
            hostRuntimeActive && hostSnapshot?.hostState == "ready"
            && hostSnapshot?.registrationStatus == "ready"
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
        let commandRetry =
            usesLegacyHost
            ? nil
            : backgroundHostCommandRetryHomeSnapshot(
                command: hostAgentBackgroundCommandPresentation, approval: approval,
                session: session)
        let clipboardPolicy = currentHostClipboardPolicy()
        let fileTransferPolicy = currentHostFileTransferPolicy()
        let audioPolicy = currentHostAudioPolicy()
        let audioInputDeviceName = UserDefaults.standard.string(
            forKey: Self.hostAudioInputDeviceNameDefaultsKey)
        let bootstrapReady: Bool
        if case .ready = hostAgentBootstrapState {
            bootstrapReady = true
        } else {
            bootstrapReady = false
        }
        homeView.apply(
            HomeSnapshot(
                server: catalog.server, devices: items,
                statusText: activeAttemptID == nil ? "就绪" : "正在建立安全连接…", errorText: error,
                connectingPeerID: pendingProductConnection?.peerID,
                viewerAudioOptIn: viewerAudioOptInForNextConnection,
                permissions: currentHomeSystemPermissions(),
                host: HostHomeSnapshot(
                    isEnabled: hostControl.isOn,
                    isControlEnabled: HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                        control: hostControl, bootstrapReady: bootstrapReady),
                    isRunning: usesLegacyHost ? hostRuntimeActive : hostReadiness.isRunning,
                    isReady: usesLegacyHost ? legacyHostIsReady : hostReadiness.isReady,
                    allowsHostCommands: usesLegacyHost
                        ? hostRuntimeActive
                        : backgroundHostPasswordPeerIdentity() != nil
                            && hostAgentPasswordActionInFlight == nil,
                    isStreaming: usesLegacyHost && hostMediaRoute != nil,
                    clipboardReadEnabled: clipboardPolicy.allowRemoteRead,
                    clipboardWriteEnabled: clipboardPolicy.allowRemoteWrite,
                    clipboardRichTextReadEnabled: clipboardPolicy.allowRemoteRichTextRead,
                    clipboardRichTextWriteEnabled: clipboardPolicy.allowRemoteRichTextWrite,
                    clipboardImageReadEnabled: clipboardPolicy.allowRemoteImageRead,
                    clipboardImageWriteEnabled: clipboardPolicy.allowRemoteImageWrite,
                    allowsClipboardPolicyChange:
                        HostAgentBackgroundHomeRoutingPolicy.allowsClipboardPolicyChange(
                            control: hostControl, viewerConnectionInProgress: activeAttemptID != nil
                        ), fileTransferEnabled: fileTransferPolicy.enabled,
                    fileTransferReceiveRootName: fileTransferPolicy.receiveRoot.map {
                        URL(fileURLWithPath: $0).lastPathComponent
                    } ?? "",
                    allowsFileTransferPolicyChange:
                        HostAgentBackgroundHomeRoutingPolicy.allowsFileTransferPolicyChange(
                            control: hostControl, viewerConnectionInProgress: activeAttemptID != nil
                        ), audioEnabled: audioPolicy.enabled,
                    audioInputDeviceNames: hostAudioInputDeviceCatalogOwner.catalog.uniqueNames,
                    audioInputDeviceName: audioInputDeviceName,
                    audioInputDeviceAvailable: audioInputDeviceName.map(
                        hostAudioInputDeviceCatalogOwner.catalog.containsUnique) ?? true,
                    microphoneAuthorizationText: hostMicrophoneAuthorizationText(),
                    allowsAudioPolicyChange:
                        HostAgentBackgroundHomeRoutingPolicy.allowsAudioPolicyChange(
                            control: hostControl,
                            viewerConnectionInProgress: activeAttemptID != nil,
                            authorizationRequestInProgress:
                                hostMicrophoneAuthorizationAuthority.isRequestPending()),
                    statusText: hostProductStatusText(
                        hostReadiness: hostReadiness, usesLegacyHost: usesLegacyHost,
                        backgroundCommand: hostAgentBackgroundCommandPresentation),
                    localID: usesLegacyHost
                        ? hostSnapshot?.localId ?? "" : backgroundSnapshot.localID,
                    temporaryPassword: hostTemporaryPassword,
                    localPermanentPasswordSet: usesLegacyHost
                        ? hostSnapshot?.passwordPolicy.localPasswordSet ?? false
                        : backgroundSnapshot.localPermanentPasswordSet,
                    effectivePermanentPasswordSet: usesLegacyHost
                        ? hostSnapshot?.passwordPolicy.effectivePasswordSet ?? false
                        : backgroundSnapshot.effectivePermanentPasswordSet,
                    usingPresetPassword: usesLegacyHost
                        ? hostSnapshot?.passwordPolicy.usingPresetPassword ?? false
                        : backgroundSnapshot.usingPresetPassword,
                    permanentPasswordChangeAllowed: usesLegacyHost
                        ? hostSnapshot?.passwordPolicy.changeAllowed ?? false
                        : backgroundSnapshot.permanentPasswordChangeAllowed,
                    pendingApproval: approval, activeSession: session, commandRetry: commandRetry,
                    mediaDiagnosticText: usesLegacyHost ? hostMediaDiagnosticText() : "",
                    errorText: combinedHostErrorText(
                        usesLegacyHost: usesLegacyHost, backgroundSnapshot: backgroundSnapshot,
                        backgroundCommand: hostAgentBackgroundCommandPresentation))))
    }

    func combinedHostErrorText(
        usesLegacyHost: Bool, backgroundSnapshot: HostAgentBackgroundHomeSnapshotPresentation,
        backgroundCommand: HostAgentBackgroundHomeCommandReadOnlyPresentation
    ) -> String {
        let bootstrapError = hostAgentBootstrapState == .degraded ? "后台 Host 配置暂时不可用。" : ""
        let backgroundRuntimeError =
            !usesLegacyHost && backgroundSnapshot.hasRuntimeError ? "后台 Host 服务暂时不可用，将继续重试。" : ""
        return [
            usesLegacyHost ? hostErrorText : "",
            hostAgentBackgroundUnregistrationPresentation?.errorText ?? "",
            hostAgentBackgroundRegistrationPresentation?.errorText ?? "",
            hostAgentBackgroundOwnershipErrorText, hostAgentBackgroundReadinessErrorText,
            backgroundRuntimeError, usesLegacyHost ? "" : hostAgentPasswordErrorText,
            usesLegacyHost ? "" : backgroundCommand.errorText, bootstrapError,
            hostFileTransferPolicyErrorText, hostAudioPolicyErrorText,
            usesLegacyHost ? "" : hostAgentRuntimeConfigurationErrorText,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var hostAgentBackgroundReadinessErrorText: String {
        guard hostAgentBackgroundRegistrationStatus != .notRegistered,
            hostAgentBackgroundFlow == nil
        else { return "" }
        return HostAgentBackgroundHomeReadinessPresentationPolicy.presentation(
            phase: coherentHostAgentBackgroundActivationView?.phase,
            registration: hostAgentBackgroundRegistrationStatus
        ).errorText
    }

    func hostProductStatusText(
        hostReadiness: HostAgentBackgroundHomeReadinessPresentation, usesLegacyHost: Bool,
        backgroundCommand: HostAgentBackgroundHomeCommandReadOnlyPresentation
    ) -> String {
        if let presentation = hostAgentBackgroundUnregistrationPresentation {
            return presentation.statusText
        }
        if let presentation = hostAgentBackgroundRegistrationPresentation {
            return presentation.statusText
        }
        if !usesLegacyHost, !backgroundCommand.statusText.isEmpty {
            return backgroundCommand.statusText
        }
        return usesLegacyHost ? hostStatusText : hostReadiness.statusText
    }

    func reconcileHostAgentBootstrap() {
        guard let hostAgentBootstrapIntegration else {
            hostAgentBootstrapState = .degraded
            return
        }
        hostAgentBootstrapState = hostAgentBootstrapIntegration.reconcileSavedCatalog(
            from: catalogStore, clipboardPolicy: currentHostClipboardPolicy(),
            fileTransferPolicy: currentHostFileTransferPolicy(),
            audioPolicy: currentHostAudioPolicy())
        refreshHostAgentRuntimeConfigurationCoherence()
    }
}
