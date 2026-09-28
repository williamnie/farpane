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
    func currentHostClipboardPolicy() -> HostAgentClipboardPolicy {
        HostClipboardPreference.policy(from: .standard)
    }

    func currentHomeSystemPermissions() -> HomeSystemPermissionSnapshot {
        let accessibilityOptions =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        let microphone: HomeSystemPermissionState
        switch hostMicrophoneAuthorizationAuthority.authorizationStatus() {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        }
        return HomeSystemPermissionSnapshot(
            screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied,
            accessibility: AXIsProcessTrustedWithOptions(accessibilityOptions) ? .granted : .denied,
            inputMonitoring: CGPreflightListenEventAccess() ? .granted : .denied,
            microphone: microphone)
    }

    func currentHostFileTransferPolicy() -> HostAgentFileTransferPolicy {
        guard UserDefaults.standard.bool(forKey: Self.hostFileTransferEnabledDefaultsKey),
            let receiveRoot = UserDefaults.standard.string(
                forKey: Self.hostFileTransferReceiveRootDefaultsKey)
        else { return .disabled }
        guard
            let restoredReceiveRoot = HostFileTransferReceiveRootProvisioner.restoreConfiguredRoot(
                at: URL(fileURLWithPath: receiveRoot)),
            let restoredPolicy = HostAgentFileTransferPolicy.validatedEnabled(
                receiveRoot: restoredReceiveRoot.path)
        else {
            hostFileTransferPolicyErrorText = "文件接收目录无法安全恢复；请在共享设置中重新选择保存位置。"
            return .disabled
        }
        hostFileTransferPolicyErrorText = ""
        return restoredPolicy
    }

    func currentHostAudioPolicy() -> HostAgentAudioPolicy {
        guard UserDefaults.standard.bool(forKey: Self.hostAudioEnabledDefaultsKey) else {
            return .disabled
        }
        let selectedName = UserDefaults.standard.string(
            forKey: Self.hostAudioInputDeviceNameDefaultsKey)
        guard selectedName.map(hostAudioInputDeviceCatalogOwner.catalog.containsUnique) ?? true,
            let policy = HostAgentAudioPolicy.validatedEnabled(inputDeviceName: selectedName)
        else { return .disabled }
        guard
            !policy.requiresMicrophoneAuthorization
                || hostMicrophoneAuthorizationAuthority.authorizationStatus() == .authorized
        else { return .disabled }
        return policy
    }

    var coherentHostAgentBackgroundActivationView: HostAgentBackgroundActivationView? {
        guard hostAgentRuntimeConfigurationCoherence.permitsRuntimeProjection else { return nil }
        return hostAgentBackgroundActivationView
    }

    func refreshHostAgentRuntimeConfigurationCoherence() {
        defer { observeHostAgentApplicationConcurrencyEvidence() }
        guard let projection = hostAgentBackgroundActivationView?.projection,
            case .available(let available) = projection.phase
        else {
            hostAgentRuntimeConfigurationCoherence = .waitingForLivePeer
            return
        }
        guard case .ready(let publishedConfigRevision) = hostAgentBootstrapState else {
            hostAgentRuntimeConfigurationCoherence = .evidenceUnavailable
            return
        }
        guard let hostAgentRuntimeConfigurationReader else {
            hostAgentRuntimeConfigurationCoherence = .evidenceUnavailable
            return
        }
        do {
            let observation = try hostAgentRuntimeConfigurationReader.load()
            guard observation.bootstrap.configRevision == publishedConfigRevision else {
                hostAgentRuntimeConfigurationCoherence = .evidenceUnavailable
                return
            }
            hostAgentRuntimeConfigurationCoherence =
                HostAgentRuntimeConfigurationCoherencePolicy.evaluate(
                    observation: observation, liveAgentBuildID: available.peerIdentity.agentBuildID,
                    liveAgentBootID: available.peerIdentity.agentBootID)
        } catch { hostAgentRuntimeConfigurationCoherence = .evidenceUnavailable }
    }

    func handleHostProductToggle(_ enabled: Bool) {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated { handleHostProductToggleOnMain(enabled) }
    }

    func handleHostClipboardPolicyToggle(_ preference: HostClipboardPreference, enabled: Bool) {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated {
            let legacy = HostAgentLegacyHostMigrationGate.assess(
                captureLegacyHostMigrationEvidence())
            let control = HostAgentBackgroundHomeRoutingPolicy.controlState(
                registration: hostAgentBackgroundRegistrationStatus, legacy: legacy,
                flow: hostAgentBackgroundFlow)
            guard
                HostAgentBackgroundHomeRoutingPolicy.allowsClipboardPolicyChange(
                    control: control, viewerConnectionInProgress: activeAttemptID != nil)
            else {
                refreshHomeUI()
                return
            }

            UserDefaults.standard.set(enabled, forKey: preference.defaultsKey)
            reconcileHostAgentBootstrap()
            refreshHomeUI()
        }
    }

    func handleHostFileTransferPolicyToggle(_ enabled: Bool) {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated {
            guard hostFileTransferPolicyChangeAllowed() else {
                refreshHomeUI()
                return
            }
            if enabled {
                beginHostFileTransferReceiveRootSelection()
                refreshHomeUI()
                return
            }

            let picker = hostFileTransferReceiveRootPicker
            hostFileTransferReceiveRootPicker = nil
            picker?.cancel()
            UserDefaults.standard.set(false, forKey: Self.hostFileTransferEnabledDefaultsKey)
            UserDefaults.standard.removeObject(forKey: Self.hostFileTransferReceiveRootDefaultsKey)
            hostFileTransferPolicyErrorText = ""
            reconcileHostAgentBootstrap()
            refreshHomeUI()
        }
    }

    func beginHostFileTransferReceiveRootSelection() {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated {
            guard hostFileTransferPolicyChangeAllowed(), hostFileTransferReceiveRootPicker == nil,
                let window
            else {
                refreshHomeUI()
                return
            }
            let picker = HostFileTransferReceiveRootPickerController()
            hostFileTransferReceiveRootPicker = picker
            picker.begin(on: window) { [weak self, weak picker] result in
                guard let self, let picker, self.hostFileTransferReceiveRootPicker === picker else {
                    return
                }
                self.hostFileTransferReceiveRootPicker = nil
                switch result {
                case .selected(let receiveRoot):
                    guard
                        let policy = HostAgentFileTransferPolicy.validatedEnabled(
                            receiveRoot: receiveRoot), let canonicalReceiveRoot = policy.receiveRoot
                    else {
                        self.hostFileTransferPolicyErrorText = "接收文件夹路径无效，文件接收仍保持关闭。"
                        self.refreshHomeUI()
                        return
                    }
                    UserDefaults.standard.set(
                        canonicalReceiveRoot, forKey: Self.hostFileTransferReceiveRootDefaultsKey)
                    UserDefaults.standard.set(true, forKey: Self.hostFileTransferEnabledDefaultsKey)
                    self.hostFileTransferPolicyErrorText = ""
                    self.reconcileHostAgentBootstrap()
                case .cancelled: break
                case .rejected:
                    self.hostFileTransferPolicyErrorText =
                        "无法创建私有 FarPane Receive 文件夹；请选择属于当前用户且不可被其他用户写入的位置。"
                }
                self.refreshHomeUI()
            }
        }
    }

    @MainActor func hostFileTransferPolicyChangeAllowed() -> Bool {
        let legacy = HostAgentLegacyHostMigrationGate.assess(captureLegacyHostMigrationEvidence())
        let control = HostAgentBackgroundHomeRoutingPolicy.controlState(
            registration: hostAgentBackgroundRegistrationStatus, legacy: legacy,
            flow: hostAgentBackgroundFlow)
        return HostAgentBackgroundHomeRoutingPolicy.allowsFileTransferPolicyChange(
            control: control, viewerConnectionInProgress: activeAttemptID != nil)
    }
}
