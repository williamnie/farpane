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
    @MainActor func beginHostAgentBackgroundRegistration() -> Bool {
        guard let window else { return false }
        return hostAgentBackgroundRegistrationSheetDriver.begin(on: window) { [weak self] view in
            self?.routeHostAgentBackgroundRegistrationCompletion(view)
        }
    }

    @MainActor func beginHostAgentBackgroundUnregistration() -> Bool {
        guard let window else { return false }
        return hostAgentBackgroundUnregistrationSheetDriver.begin(on: window) { [weak self] view in
            self?.routeHostAgentBackgroundUnregistrationCompletion(view)
        }
    }

    @MainActor func routeHostAgentBackgroundRegistrationCompletion(
        _ view: HostAgentBackgroundRegistrationUXView
    ) {
        guard hostAgentBackgroundFlow == .registration else {
            applyHostAgentBackgroundProductRoutingDecision(.invalidCompletion)
            refreshHomeUI()
            return
        }
        hostAgentBackgroundFlow = nil
        let decision = HostAgentBackgroundProductRoutingPolicy.registrationDecision(view)
        acceptHostAgentBackgroundRegistration(view.registration, decision: decision)
        applyHostAgentBackgroundProductRoutingDecision(decision)
        refreshHomeUI()
    }

    @MainActor func routeHostAgentBackgroundUnregistrationCompletion(
        _ view: HostAgentBackgroundUnregistrationUXView
    ) {
        guard hostAgentBackgroundFlow == .unregistration else {
            applyHostAgentBackgroundProductRoutingDecision(.invalidCompletion)
            refreshHomeUI()
            return
        }
        hostAgentBackgroundFlow = nil
        let decision = HostAgentBackgroundProductRoutingPolicy.unregistrationDecision(view)
        acceptHostAgentBackgroundRegistration(view.registration, decision: decision)
        applyHostAgentBackgroundProductRoutingDecision(decision)
        refreshHomeUI()
    }

    @MainActor func acceptHostAgentBackgroundRegistration(
        _ registration: HostAgentBackgroundRegistrationStatus?,
        decision: HostAgentBackgroundProductRoutingDecision
    ) {
        if decision == .invalidCompletion {
            hostAgentBackgroundRegistrationStatus = .serviceUnavailable
            hostAgentBackgroundOwnershipErrorText = "后台组件返回了不一致状态；已停止本地观察。"
        } else if let registration {
            hostAgentBackgroundRegistrationStatus = registration
            hostAgentBackgroundOwnershipErrorText = ""
            recordCurrentHostAgentRegistrationBuildIfEnabled()
        }
    }

    @MainActor func applyHostAgentBackgroundProductRoutingDecision(
        _ decision: HostAgentBackgroundProductRoutingDecision
    ) {
        switch decision {
        case .noChange: break
        case .enableAndRefresh:
            _ = hostAgentBackgroundActivationOwner.apply(.hostEnabled)
            hostAgentBackgroundActivationOwner.refreshRegistration()
        case .disable, .invalidCompletion: disableHostAgentBackgroundObservation()
        }
    }

    @MainActor func disableHostAgentBackgroundObservation() {
        cancelBackgroundPasswordOperation()
        hostAgentBackgroundActivationView = nil
        _ = hostAgentBackgroundActivationOwner.apply(.hostDisabled)
        refreshHostAgentBackgroundCommandPresentation()
    }

    @MainActor func applyHostAgentBackgroundActivationView(
        _ view: HostAgentBackgroundActivationView
    ) {
        hostAgentBackgroundActivationView = view
        switch view.phase {
        case .monitoring(_, let readiness):
            hostAgentBackgroundRegistrationStatus = readiness.registration
            switch readiness.registration {
            case .notRegistered:
                hostAgentBackgroundOwnershipErrorText = ""
                disableHostAgentBackgroundObservation()
            case .serviceUnavailable:
                hostAgentBackgroundOwnershipErrorText = "后台组件需要重新注册；请重新开启“允许连接此 Mac”完成恢复。"
            case .enabled, .requiresApproval: hostAgentBackgroundOwnershipErrorText = ""
            }
        case .failed: hostAgentBackgroundOwnershipErrorText = ""
        case .idle, .starting, .disabled, .terminated: break
        }
        refreshHostAgentBackgroundCommandPresentation()
        recordHostRuntimeStateEvidence(force: true)
        if backgroundHostPasswordPeerIdentity() == nil {
            cancelBackgroundPasswordOperation()
            hostTemporaryPassword = ""
        }
        refreshHomeUI()
    }

    @MainActor func refreshHostAgentBackgroundCommandPresentation() {
        refreshHostAgentRuntimeConfigurationCoherence()
        _ = hostAgentBackgroundCommandPresentationOwner.refresh()
        projectHostAgentBackgroundCommandPresentation(
            hostAgentBackgroundCommandPresentationOwner.snapshot())
    }

    @MainActor func applyHostAgentBackgroundCommandPresentation(
        _ view: HostAgentBackgroundHomeCommandPresentationView
    ) {
        projectHostAgentBackgroundCommandPresentation(view)
        refreshHomeUI()
    }

    @MainActor func handleHostProductToggleOnMain(_ enabled: Bool) {
        let legacy = HostAgentLegacyHostMigrationGate.assess(captureLegacyHostMigrationEvidence())
        let control = HostAgentBackgroundHomeRoutingPolicy.controlState(
            registration: hostAgentBackgroundRegistrationStatus, legacy: legacy,
            flow: hostAgentBackgroundFlow)
        let bootstrapReady: Bool
        if case .ready = hostAgentBootstrapState {
            bootstrapReady = true
        } else {
            bootstrapReady = false
        }
        guard
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: control, bootstrapReady: bootstrapReady)
        else {
            refreshHomeUI()
            return
        }
        let route = HostAgentBackgroundHomeRoutingPolicy.toggleRoute(
            requestedEnabled: enabled, registration: hostAgentBackgroundRegistrationStatus,
            legacy: legacy, flow: hostAgentBackgroundFlow)
        switch route {
        case .noAction: break
        case .stopLegacyHost:
            hostAgentAutomaticRegistrationAttempted = true
            _ = stopHostMode(preservePreference: false, reason: .userRequest, releaseClient: true)
        case .beginRegistration:
            hostAgentBackgroundFlow = .registration
            if !beginHostAgentBackgroundRegistration() { hostAgentBackgroundFlow = nil }
        case .beginUnregistration:
            hostAgentAutomaticRegistrationAttempted = true
            hostAgentBackgroundFlow = .unregistration
            if !beginHostAgentBackgroundUnregistration() { hostAgentBackgroundFlow = nil }
        }
        refreshHomeUI()
    }

    func reconcileHostProductOwnership() {
        guard Thread.isMainThread else { return }
        MainActorBackport.assumeIsolated { reconcileHostProductOwnershipOnMain() }
    }

    @MainActor func reconcileHostProductOwnershipOnMain() {
        guard hostAgentBackgroundFlow == nil else { return }
        hostAgentBackgroundRegistrationStatus =
            HostAgentBackgroundServiceObserver.observeRegistrationStatus()
        guard refreshRegisteredHostAgentForCurrentBuildIfNeeded() else {
            refreshHomeUI()
            return
        }
        if hostAgentBackgroundRegistrationStatus == .enabled {
            hostAgentBackgroundRegistrationPresentation = nil
        }
        let legacy = HostAgentLegacyHostMigrationGate.assess(captureLegacyHostMigrationEvidence())
        let bootstrapReady: Bool
        if case .ready = hostAgentBootstrapState {
            bootstrapReady = true
        } else {
            bootstrapReady = false
        }
        if HostAgentBackgroundHomeRoutingPolicy.shouldAutomaticallyRegister(
            registration: hostAgentBackgroundRegistrationStatus, legacy: legacy,
            bootstrapReady: bootstrapReady,
            alreadyAttempted: hostAgentAutomaticRegistrationAttempted)
        {
            registerHostAgentBackgroundAutomatically()
            return
        }
        let route = HostAgentBackgroundHomeRoutingPolicy.launchRoute(
            registration: hostAgentBackgroundRegistrationStatus, legacy: legacy)
        switch route {
        case .preserveLegacyHost:
            hostAgentBackgroundOwnershipErrorText = ""
            disableHostAgentBackgroundObservation()
            if UserDefaults.standard.bool(forKey: Self.hostEnabledDefaultsKey), !hostRuntimeActive {
                startHostMode()
            }
        case .observeBackground:
            hostAgentBackgroundOwnershipErrorText = ""
            _ = hostAgentBackgroundActivationOwner.apply(.hostEnabled)
            hostAgentBackgroundActivationOwner.refreshRegistration()
        case .quiesceLegacyThenObserveBackground: reconcileRegisteredBackgroundAgainstLegacyHost()
        case .hold:
            disableHostAgentBackgroundObservation()
            updateHeldHostProductError(legacy: legacy)
        }
    }

    @MainActor func refreshRegisteredHostAgentForCurrentBuildIfNeeded() -> Bool {
        let currentBuildIdentifier =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let registeredBuildIdentifier = UserDefaults.standard.string(
            forKey: Self.hostAgentRegisteredBuildDefaultsKey)
        let decision = HostAgentBackgroundRegistrationRefreshPolicy.decision(
            registration: hostAgentBackgroundRegistrationStatus,
            currentBuildIdentifier: currentBuildIdentifier,
            registeredBuildIdentifier: registeredBuildIdentifier,
            alreadyAttempted: hostAgentRegistrationRefreshAttempted)
        guard case .refresh(let buildIdentifier) = decision else { return true }

        hostAgentRegistrationRefreshAttempted = true
        disableHostAgentBackgroundObservation()
        guard hostAgentBackgroundRegistrationMutationOwner.apply(.unregisterBackgroundAgent),
            hostAgentBackgroundRegistrationMutationOwner.snapshot().registration == .notRegistered
        else {
            hostAgentBackgroundRegistrationStatus =
                HostAgentBackgroundServiceObserver.observeRegistrationStatus()
            hostAgentBackgroundOwnershipErrorText = "后台组件升级刷新失败；请关闭并重新开启“允许连接此 Mac”。"
            return false
        }

        let registered = hostAgentBackgroundRegistrationMutationOwner.apply(
            .registerBackgroundAgent)
        hostAgentBackgroundRegistrationStatus =
            hostAgentBackgroundRegistrationMutationOwner.snapshot().registration
            ?? HostAgentBackgroundServiceObserver.observeRegistrationStatus()
        guard registered, hostAgentBackgroundRegistrationStatus == .enabled else {
            hostAgentBackgroundOwnershipErrorText = "新版后台组件未能重新注册；请重新开启“允许连接此 Mac”。"
            return false
        }
        UserDefaults.standard.set(buildIdentifier, forKey: Self.hostAgentRegisteredBuildDefaultsKey)
        hostAgentBackgroundOwnershipErrorText = ""
        return true
    }

    func recordCurrentHostAgentRegistrationBuildIfEnabled() {
        guard hostAgentBackgroundRegistrationStatus == .enabled,
            let buildIdentifier = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String,
            HostAgentRegistrationBundlePreflight.validBuildIdentifier(buildIdentifier)
        else { return }
        UserDefaults.standard.set(buildIdentifier, forKey: Self.hostAgentRegisteredBuildDefaultsKey)
    }

    @MainActor func registerHostAgentBackgroundAutomatically() {
        guard hostAgentBackgroundFlow == nil, !hostAgentAutomaticRegistrationAttempted else {
            return
        }
        hostAgentAutomaticRegistrationAttempted = true
        hostAgentBackgroundFlow = .registration
        hostAgentBackgroundRegistrationPresentation = HostAgentBackgroundRegistrationPresentation(
            statusText: "正在启用被控端…", errorText: "", tone: .progress, isBusy: true, canRetry: false)
        refreshHomeUI()

        let (migrationAccepted, migration) = prepareLegacyHostForBackgroundRegistration()
        guard migrationAccepted, migration.phase == .readyForRegistration else {
            hostAgentBackgroundFlow = nil
            hostAgentBackgroundRegistrationPresentation =
                HostAgentBackgroundRegistrationPresentation(
                    statusText: "被控端自动启用失败", errorText: "无法确认旧版 Host 已安全停止；可使用开关重试。",
                    tone: .failure, isBusy: false, canRetry: true)
            refreshHomeUI()
            return
        }

        _ = hostAgentBackgroundRegistrationMutationOwner.apply(.registerBackgroundAgent)
        let mutation = hostAgentBackgroundRegistrationMutationOwner.snapshot()
        hostAgentBackgroundFlow = nil
        hostAgentBackgroundRegistrationStatus =
            mutation.registration ?? HostAgentBackgroundServiceObserver.observeRegistrationStatus()

        switch hostAgentBackgroundRegistrationStatus {
        case .enabled:
            recordCurrentHostAgentRegistrationBuildIfEnabled()
            hostAgentBackgroundRegistrationPresentation = nil
            hostAgentBackgroundOwnershipErrorText = ""
            _ = hostAgentBackgroundActivationOwner.apply(.hostEnabled)
            hostAgentBackgroundActivationOwner.refreshRegistration()
        case .requiresApproval:
            hostAgentBackgroundRegistrationPresentation =
                HostAgentBackgroundRegistrationPresentation(
                    statusText: "等待系统允许后台组件", errorText: "首次使用请在“系统设置 > 通用 > 登录项与扩展”中允许 FarPane。",
                    tone: .attention, isBusy: false, canRetry: true)
            hostAgentBackgroundOwnershipErrorText = ""
            _ = hostAgentBackgroundActivationOwner.apply(.hostEnabled)
            hostAgentBackgroundActivationOwner.refreshRegistration()
        case .notRegistered, .serviceUnavailable:
            hostAgentBackgroundRegistrationPresentation =
                HostAgentBackgroundRegistrationPresentation(
                    statusText: "被控端自动启用失败", errorText: "后台组件未能自动注册；可使用开关重试。", tone: .failure,
                    isBusy: false, canRetry: true)
            disableHostAgentBackgroundObservation()
        }
        refreshHomeUI()
    }

    @MainActor func reconcileRegisteredBackgroundAgainstLegacyHost() {
        let (accepted, migration) = prepareLegacyHostForBackgroundRegistration()
        guard accepted, migration.phase == .readyForRegistration else {
            hostAgentBackgroundOwnershipErrorText = "后台组件已注册，但旧版 Host 尚未安全停止；已暂停新的控制操作。"
            disableHostAgentBackgroundObservation()
            return
        }

        hostAgentBackgroundRegistrationStatus =
            HostAgentBackgroundServiceObserver.observeRegistrationStatus()
        switch hostAgentBackgroundRegistrationStatus {
        case .enabled, .requiresApproval:
            hostAgentBackgroundOwnershipErrorText = ""
            _ = hostAgentBackgroundActivationOwner.apply(.hostEnabled)
            hostAgentBackgroundActivationOwner.refreshRegistration()
        case .notRegistered, .serviceUnavailable:
            hostAgentBackgroundOwnershipErrorText = "后台组件注册状态已变化；已停止本地观察。"
            disableHostAgentBackgroundObservation()
        }
    }

    @MainActor func updateHeldHostProductError(legacy: HostAgentLegacyHostMigrationAssessment) {
        if case .failed = legacy {
            hostAgentBackgroundOwnershipErrorText = "无法确认旧版 Host 是否已停止；已暂停开关。"
        } else if hostAgentBackgroundRegistrationStatus == .serviceUnavailable {
            let control = HostAgentBackgroundHomeRoutingPolicy.controlState(
                registration: hostAgentBackgroundRegistrationStatus, legacy: legacy, flow: nil)
            hostAgentBackgroundOwnershipErrorText =
                control.isOn
                ? "后台组件需要重新注册；请先关闭当前 Host，再重新开启以完成恢复。" : "后台组件需要重新注册；请重新开启“允许连接此 Mac”完成恢复。"
        } else {
            hostAgentBackgroundOwnershipErrorText = ""
        }
    }

    @MainActor func captureLegacyHostMigrationEvidence() -> HostAgentLegacyHostMigrationEvidence {
        HostAgentLegacyHostProductEvidencePolicy.evidence(
            HostAgentLegacyHostProductObservation(
                preferenceEnabled: UserDefaults.standard.bool(forKey: Self.hostEnabledDefaultsKey),
                runtimeActive: hostRuntimeActive, clientRetained: hostClient != nil,
                session: hostSnapshot.map { snapshot in
                    .available(
                        pendingApproval: snapshot.pendingApproval != nil,
                        activeSession: snapshot.activeSession != nil)
                } ?? .unavailable, mediaPipelineActive: hostMediaPipeline != nil,
                pollerActive: hostPollTimer != nil,
                runtimeQuiescenceConfirmed: hostRuntimeQuiescenceConfirmed))
    }

    @MainActor func requestLegacyHostQuiescence() -> HostAgentLegacyHostQuiescenceRequestResult {
        guard hostSnapshot?.pendingApproval == nil, hostSnapshot?.activeSession == nil else {
            return .failed
        }
        return stopHostMode(preservePreference: false, reason: .userRequest, releaseClient: true)
            ? .completed : .failed
    }

    @MainActor @discardableResult func prepareLegacyHostForBackgroundRegistration() -> (
        Bool, HostAgentLegacyHostMigrationCoordinatorView
    ) {
        let accepted = hostAgentLegacyMigrationCoordinator.apply(.prepareForBackgroundRegistration)
        return (accepted, hostAgentLegacyMigrationCoordinator.snapshot())
    }

    @MainActor func applyHostAgentBackgroundRegistrationPresentation(
        _ view: HostAgentBackgroundRegistrationUXView
    ) {
        hostAgentBackgroundUnregistrationPresentation = nil
        hostAgentBackgroundRegistrationPresentation =
            HostAgentBackgroundRegistrationPresentationPolicy.presentation(for: view)
        refreshHomeUI()
    }

    @MainActor func applyHostAgentBackgroundUnregistrationPresentation(
        _ view: HostAgentBackgroundUnregistrationUXView
    ) {
        hostAgentBackgroundRegistrationPresentation = nil
        hostAgentBackgroundUnregistrationPresentation =
            HostAgentBackgroundUnregistrationPresentationPolicy.presentation(for: view)
        refreshHomeUI()
    }
}
