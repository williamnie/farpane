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
    func handleHostAudioPolicyToggle(_ enabled: Bool) {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated {
            guard hostAudioPolicyChangeAllowed() else {
                refreshHomeUI()
                return
            }
            if !enabled {
                UserDefaults.standard.set(false, forKey: Self.hostAudioEnabledDefaultsKey)
                hostAudioPolicyErrorText = ""
                reconcileHostAgentBootstrap()
                refreshHomeUI()
                return
            }

            _ = hostAudioInputDeviceCatalogOwner.refresh()
            if let selectedName = UserDefaults.standard.string(
                forKey: Self.hostAudioInputDeviceNameDefaultsKey),
                !hostAudioInputDeviceCatalogOwner.catalog.containsUnique(selectedName)
            {
                UserDefaults.standard.set(false, forKey: Self.hostAudioEnabledDefaultsKey)
                hostAudioPolicyErrorText = "已选音频输入不可用或名称不唯一；远程音频保持关闭。"
                reconcileHostAgentBootstrap()
                refreshHomeUI()
                return
            }

            enableHostAudioForCurrentSource()
        }
    }

    @MainActor func enableHostAudioForCurrentSource() {
        let selectedName = UserDefaults.standard.string(
            forKey: Self.hostAudioInputDeviceNameDefaultsKey)
        if selectedName == nil {
            commitHostAudioEnabled()
            return
        }
        switch hostMicrophoneAuthorizationAuthority.authorizationStatus() {
        case .authorized: commitHostAudioEnabled()
        case .denied, .restricted:
            UserDefaults.standard.set(false, forKey: Self.hostAudioEnabledDefaultsKey)
            hostAudioPolicyErrorText = "麦克风权限未授权；请在系统设置的“隐私与安全性”中允许 FarPane 使用麦克风。"
            reconcileHostAgentBootstrap()
            refreshHomeUI()
        case .notDetermined:
            let result = hostMicrophoneAuthorizationAuthority.requestAuthorization {
                [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    self?.completeHostMicrophoneAuthorization(status)
                }
            }
            switch result {
            case .admitted, .busy: refreshHomeUI()
            case .alreadyAuthorized: commitHostAudioEnabled()
            case .unavailable:
                hostAudioPolicyErrorText = "麦克风权限不可用，远程音频仍保持关闭。"
                refreshHomeUI()
            }
        }
    }

    func handleHostAudioInputSelection(_ name: String?) {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated {
            guard hostAudioPolicyChangeAllowed() else {
                refreshHomeUI()
                return
            }
            _ = hostAudioInputDeviceCatalogOwner.refresh()
            let wasEnabled = UserDefaults.standard.bool(forKey: Self.hostAudioEnabledDefaultsKey)
            if let name {
                guard hostAudioInputDeviceCatalogOwner.catalog.containsUnique(name) else {
                    UserDefaults.standard.set(false, forKey: Self.hostAudioEnabledDefaultsKey)
                    hostAudioPolicyErrorText = "所选音频输入不可用或名称不唯一；远程音频保持关闭。"
                    reconcileHostAgentBootstrap()
                    refreshHomeUI()
                    return
                }
                UserDefaults.standard.set(name, forKey: Self.hostAudioInputDeviceNameDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.hostAudioInputDeviceNameDefaultsKey)
            }
            hostAudioPolicyErrorText = ""
            if wasEnabled {
                enableHostAudioForCurrentSource()
                return
            }
            reconcileHostAgentBootstrap()
            refreshHomeUI()
        }
    }

    func refreshHostAudioInputs() {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated {
            guard hostAudioPolicyChangeAllowed() else {
                refreshHomeUI()
                return
            }
            let succeeded = hostAudioInputDeviceCatalogOwner.refresh()
            if !succeeded {
                hostAudioPolicyErrorText = "无法读取音频输入设备；显式设备音频保持关闭。"
            } else if let selectedName = UserDefaults.standard.string(
                forKey: Self.hostAudioInputDeviceNameDefaultsKey),
                !hostAudioInputDeviceCatalogOwner.catalog.containsUnique(selectedName)
            {
                hostAudioPolicyErrorText = "已选音频输入不可用或名称不唯一；不会回退系统音频。"
            } else {
                hostAudioPolicyErrorText = ""
            }
            reconcileHostAgentBootstrap()
            refreshHomeUI()
        }
    }

    @MainActor func completeHostMicrophoneAuthorization(_ status: HostMicrophoneAuthorizationStatus)
    {
        guard status == .authorized, hostAudioPolicyChangeAllowed() else {
            UserDefaults.standard.set(false, forKey: Self.hostAudioEnabledDefaultsKey)
            hostAudioPolicyErrorText =
                status == .authorized ? "Host 状态已变化，麦克风授权已保留，但远程音频仍保持关闭。" : "麦克风权限未授权，远程音频仍保持关闭。"
            reconcileHostAgentBootstrap()
            refreshHomeUI()
            return
        }
        commitHostAudioEnabled()
    }

    @MainActor func commitHostAudioEnabled() {
        UserDefaults.standard.set(true, forKey: Self.hostAudioEnabledDefaultsKey)
        hostAudioPolicyErrorText = ""
        reconcileHostAgentBootstrap()
        refreshHomeUI()
    }

    @MainActor func hostAudioPolicyChangeAllowed() -> Bool {
        let legacy = HostAgentLegacyHostMigrationGate.assess(captureLegacyHostMigrationEvidence())
        let control = HostAgentBackgroundHomeRoutingPolicy.controlState(
            registration: hostAgentBackgroundRegistrationStatus, legacy: legacy,
            flow: hostAgentBackgroundFlow)
        return HostAgentBackgroundHomeRoutingPolicy.allowsAudioPolicyChange(
            control: control, viewerConnectionInProgress: activeAttemptID != nil,
            authorizationRequestInProgress: hostMicrophoneAuthorizationAuthority.isRequestPending())
    }

    func hostMicrophoneAuthorizationText() -> String {
        guard UserDefaults.standard.string(forKey: Self.hostAudioInputDeviceNameDefaultsKey) != nil
        else { return "系统音频使用屏幕录制权限；不需要麦克风权限" }
        if hostMicrophoneAuthorizationAuthority.isRequestPending() { return "麦克风权限：等待确认" }
        switch hostMicrophoneAuthorizationAuthority.authorizationStatus() {
        case .authorized: return "麦克风权限：已授权"
        case .notDetermined: return "麦克风权限：开启时询问"
        case .denied: return "麦克风权限：未授权"
        case .restricted: return "麦克风权限：受系统限制"
        }
    }
}
