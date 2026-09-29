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
    func revealHostTemporaryPassword(completion: ((String?) -> Void)? = nil) {
        if !hostTemporaryPassword.isEmpty {
            hostTemporaryPassword = ""
            hostPasswordHideTimer?.invalidate()
            hostPasswordHideTimer = nil
            refreshHomeUI()
            completion?(nil)
            return
        }
        if let hostClient, hostRuntimeActive {
            revealLegacyHostTemporaryPassword(hostClient: hostClient, completion: completion)
            return
        }
        startBackgroundPasswordOperation(.revealTemporaryPassword) { result in
            let password: String?
            if case .succeeded(let revealed) = result {
                password = revealed
            } else {
                password = nil
            }
            completion?(password)
        }
    }

    func revealLegacyHostTemporaryPassword(
        hostClient: HostControlClient, completion: ((String?) -> Void)?
    ) {
        do {
            let password = try hostClient.revealTemporaryPassword(commandId: UUID().uuidString)
            let snapshot = try hostClient.copySnapshot()
            hostSnapshot = snapshot
            hostTemporaryPassword = password
            hostPasswordHideTimer?.invalidate()
            hostPasswordHideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) {
                [weak self] _ in
                self?.hostTemporaryPassword = ""
                self?.refreshHomeUI()
            }
            hostErrorText = ""
            completion?(password)
        } catch {
            hostTemporaryPassword = ""
            hostErrorText = sanitizedHostError(error)
            completion?(nil)
        }
        refreshHomeUI()
    }

    func copyHostTemporaryPassword() {
        if !hostTemporaryPassword.isEmpty {
            let copied = viewerPasteboardOwner.writeLocalProductText(hostTemporaryPassword)
            homeView?.reportHostTemporaryPasswordCopy(copied)
            return
        }
        revealHostTemporaryPassword { [weak self] password in
            guard let self else { return }
            let copied = password.map(self.viewerPasteboardOwner.writeLocalProductText) ?? false
            self.homeView?.reportHostTemporaryPasswordCopy(copied)
        }
    }

    func regenerateHostTemporaryPassword() {
        if let hostClient, hostRuntimeActive {
            regenerateLegacyHostTemporaryPassword(hostClient: hostClient)
            return
        }
        startBackgroundPasswordOperation(.regenerateTemporaryPassword) { [weak self] result in
            guard let self, case .succeeded = result else { return }
            self.startBackgroundPasswordOperation(.revealTemporaryPassword)
        }
    }

    func regenerateLegacyHostTemporaryPassword(hostClient: HostControlClient) {
        do {
            try hostClient.regenerateTemporaryPassword(commandId: UUID().uuidString)
            hostTemporaryPassword = ""
            hostPasswordHideTimer?.invalidate()
            hostPasswordHideTimer = nil
            hostErrorText = ""
            revealLegacyHostTemporaryPassword(hostClient: hostClient, completion: nil)
        } catch {
            hostErrorText = sanitizedHostError(error)
            refreshHomeUI()
        }
    }

    func presentHostPermanentPassword() {
        guard let policy = currentHostPermanentPasswordPolicy(), policy.changeAllowed, let window
        else { return }
        let legacyClient = hostRuntimeActive ? hostClient : nil
        let prompt = HostPermanentPasswordPromptController()
        hostPermanentPasswordPrompt = prompt
        prompt.begin(on: window, policy: policy) { [weak self] secret in
            guard let self else {
                secret?.wipe()
                return
            }
            self.hostPermanentPasswordPrompt = nil
            guard let secret else { return }
            defer { secret.wipe() }
            if let legacyClient {
                guard self.hostRuntimeActive, self.hostClient === legacyClient else {
                    self.hostErrorText = "Host 状态已变化，请重新设置永久密码。"
                    self.refreshHomeUI()
                    return
                }
                do {
                    try legacyClient.setPermanentPassword(&secret.data)
                    self.hostErrorText = ""
                    self.refreshHostSnapshot()
                } catch {
                    self.hostErrorText = self.sanitizedHostError(error)
                    self.refreshHomeUI()
                }
            } else {
                self.startBackgroundPasswordOperation(
                    .setPermanentPassword, secretData: secret.data)
            }
        }
    }

    func confirmClearHostPermanentPassword() {
        guard let policy = currentHostPermanentPasswordPolicy(), policy.changeAllowed,
            policy.localPasswordSet, let window
        else { return }
        let legacyClient = hostRuntimeActive ? hostClient : nil
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除本机永久密码？"
        alert.informativeText = "清除后将不能再使用这个本机永久密码连接；临时密码不受影响。" + "如果管理员预设了密码，预设密码仍会生效。"
        alert.addButton(withTitle: "清除")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self, weak legacyClient] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            if let legacyClient {
                guard self.hostRuntimeActive, self.hostClient === legacyClient else { return }
                do {
                    try legacyClient.clearPermanentPassword(commandId: UUID().uuidString)
                    self.hostErrorText = ""
                    self.refreshHostSnapshot()
                } catch {
                    self.hostErrorText = self.sanitizedHostError(error)
                    self.refreshHomeUI()
                }
            } else {
                self.startBackgroundPasswordOperation(.clearPermanentPassword)
            }
        }
    }

    func backgroundHostPasswordPeerIdentity() -> HostAgentXPCSnapshotClientPeerIdentity? {
        guard hostAgentBackgroundRegistrationStatus == .enabled, hostAgentBackgroundFlow == nil,
            let projection = coherentHostAgentBackgroundActivationView?.projection,
            case .available(let available) = projection.phase
        else { return nil }
        return available.peerIdentity
    }

    func currentHostPermanentPasswordPolicy() -> HostPermanentPasswordPolicy? {
        if hostRuntimeActive { return hostSnapshot?.passwordPolicy }
        guard let projection = coherentHostAgentBackgroundActivationView?.projection,
            case .available(let available) = projection.phase
        else { return nil }
        let value = available.payload.passwordPolicy
        return HostPermanentPasswordPolicy(
            localPasswordSet: value.localPasswordSet,
            effectivePasswordSet: value.effectivePasswordSet,
            usingPresetPassword: value.usingPresetPassword, changeAllowed: value.changeAllowed,
            strengthPolicyVersion: value.strengthPolicyVersion,
            minimumCharacters: value.minimumCharacters, maximumCharacters: value.maximumCharacters,
            maximumUTF8Bytes: value.maximumUTF8Bytes,
            rejectsControlCharacters: value.rejectsControlCharacters,
            rejectsOuterWhitespace: value.rejectsOuterWhitespace)
    }

    func startBackgroundPasswordOperation(
        _ action: HostAgentXPCPasswordAction, secretData: Data = Data(),
        completion: ((HostAgentXPCPasswordOperationResult) -> Void)? = nil
    ) {
        guard hostAgentPasswordOperationOwner == nil,
            let peerIdentity = backgroundHostPasswordPeerIdentity()
        else {
            hostAgentPasswordErrorText = "Host 密码操作暂时不可用，请重试。"
            refreshHomeUI()
            completion?(.unavailable)
            return
        }
        guard
            let owner = try? HostAgentXPCPasswordOperationOwner.makeProduct(
                expectedPeerIdentity: peerIdentity, action: action, secretData: secretData)
        else {
            hostAgentPasswordErrorText = "Host 密码操作暂时不可用，请重试。"
            refreshHomeUI()
            completion?(.unavailable)
            return
        }
        hostAgentPasswordOperationOwner = owner
        hostAgentPasswordActionInFlight = action
        hostAgentPasswordErrorText = ""
        refreshHomeUI()
        let started = owner.start { [weak self, weak owner] result in
            DispatchQueue.main.async { [weak self, weak owner] in
                guard let self, let owner, self.hostAgentPasswordOperationOwner === owner else {
                    return
                }
                self.hostAgentPasswordOperationOwner = nil
                self.hostAgentPasswordActionInFlight = nil
                self.applyBackgroundPasswordOperationResult(result, action: action)
                self.refreshHomeUI()
                completion?(result)
            }
        }
        if !started {
            hostAgentPasswordOperationOwner = nil
            hostAgentPasswordActionInFlight = nil
            hostAgentPasswordErrorText = "Host 密码操作暂时不可用，请重试。"
            refreshHomeUI()
            completion?(.unavailable)
        }
    }

    func cancelBackgroundPasswordOperation() {
        let owner = hostAgentPasswordOperationOwner
        hostAgentPasswordOperationOwner = nil
        hostAgentPasswordActionInFlight = nil
        owner?.cancel()
    }

    func applyBackgroundPasswordOperationResult(
        _ result: HostAgentXPCPasswordOperationResult, action: HostAgentXPCPasswordAction
    ) {
        switch result {
        case .succeeded(let temporaryPassword):
            hostAgentPasswordErrorText = ""
            if action == .revealTemporaryPassword, let temporaryPassword {
                hostTemporaryPassword = temporaryPassword
                hostPasswordHideTimer?.invalidate()
                hostPasswordHideTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) {
                    [weak self] _ in
                    self?.hostTemporaryPassword = ""
                    self?.refreshHomeUI()
                }
            } else if action == .regenerateTemporaryPassword {
                hostTemporaryPassword = ""
            }
        case .rejected(let detail), .failed(let detail):
            hostAgentPasswordErrorText = passwordOperationErrorText(detail)
        case .unavailable: hostAgentPasswordErrorText = "Host 密码操作暂时不可用，请重试。"
        case .cancelled: break
        }
    }

    func passwordOperationErrorText(_ detail: HostAgentXPCPasswordDetail) -> String {
        switch detail {
        case .empty, .tooShort: return "永久密码长度不足。"
        case .tooLong: return "永久密码过长。"
        case .outerWhitespace: return "永久密码首尾不能是空白字符。"
        case .invalidCharacters: return "永久密码包含不支持的字符。"
        case .changeDisabled: return "永久密码由管理员管理，当前不允许更改。"
        case .storageFailure: return "永久密码未能安全保存，请重试。"
        case .busy: return "另一个 Host 密码操作正在进行，请稍后重试。"
        case .duplicateRequest: return "Host 密码操作已处理，请刷新后确认。"
        case .temporaryPasswordUnavailable: return "临时密码暂时无法读取，请重试。"
        case .coreUnavailable, .coreFailure, .none: return "Host 密码操作失败，请重试。"
        }
    }

    func sanitizedHostError(_ error: Error) -> String {
        switch error {
        case HostControlError.load, HostControlError.hostSurfaceUnavailable:
            return "无法加载兼容的 Host Core。"
        case HostControlError.abiMismatch, HostControlError.mediaABIMismatch,
            HostControlError.invalidUpstreamCommit:
            return "Host Core 版本不匹配。"
        case HostControlError.configRoot: return "Host 配置目录初始化失败。"
        case HostControlError.create, HostControlError.start: return "Host 服务启动失败，请检查服务器配置。"
        case HostControlError.command: return "Host 设置操作失败，请重试。"
        case HostControlError.permanentPassword:
            let failure = (error as? HostControlError)?.permanentPasswordFailure
            switch failure {
            case .empty, .tooShort: return "永久密码长度不足。"
            case .tooLong: return "永久密码过长。"
            case .outerWhitespace: return "永久密码首尾不能是空白字符。"
            case .invalidUTF8, .forbiddenCharacter: return "永久密码包含不支持的字符。"
            case .changeDisabled: return "永久密码由管理员管理，当前不允许更改。"
            case .storage: return "永久密码未能安全保存，请重试。"
            case .unknown, .none: return "永久密码设置失败，请重试。"
            }
        case HostControlError.snapshot, HostControlError.snapshotDecode: return "Host 状态暂时无法读取。"
        case HostControlError.stop: return "Host 服务未能正常停止。"
        case HostControlError.media: return "Host 媒体链暂时不可用。"
        default: return "Host 服务暂时不可用。"
        }
    }
}
