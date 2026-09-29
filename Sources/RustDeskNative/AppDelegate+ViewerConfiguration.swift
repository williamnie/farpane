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
    func environmentConnectionConfiguration() throws -> (URL, CoreConnectionConfig) {
        guard let coreLibrary = options.coreLibrary, !coreLibrary.isEmpty else {
            throw usageError("--core is required for live mode")
        }
        let server = takeEnvironment(options.serverEnvironment)
        let key = takeEnvironment(options.keyEnvironment)
        let peerID = takeEnvironment(options.peerIDEnvironment)
        let password = takeEnvironment(options.passwordEnvironment)
        guard !server.isEmpty, !key.isEmpty, !peerID.isEmpty else {
            throw usageError("live connection environment is incomplete")
        }
        return (
            URL(fileURLWithPath: coreLibrary),
            CoreConnectionConfig(
                rendezvousServer: server, serverPublicKey: key, peerID: peerID, password: password,
                forceRelay: options.forceRelay, receiveClipboardText: true, sendClipboardText: true,
                receiveClipboardRichText: true, sendClipboardRichText: true,
                receiveClipboardImage: true, sendClipboardImage: true)
        )
    }

    func takeEnvironment(_ name: String) -> String {
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        unsetenv(name)
        return value
    }

    func defaultCorePath() -> String {
        if let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent(
            "liblibrustdesk.dylib"), FileManager.default.fileExists(atPath: bundled.path)
        {
            return bundled.path
        }
        #if arch(x86_64)
            let architecture = "x86_64"
        #else
            let architecture = "arm64"
        #endif
        let sibling = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(
            "CoreBridge/\(architecture)/liblibrustdesk.dylib")
        if FileManager.default.fileExists(atPath: sibling.path) { return sibling.path }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Build/CoreBridge/\(architecture)/liblibrustdesk.dylib").path
    }

    func sanitizedStartupError(_ error: Error) -> String {
        switch error {
        case CoreBridgeError.load(_): return "无法加载兼容的 RustDesk Core，请检查动态库与 ABI。"
        case CoreBridgeError.createClient: return "无法创建连接会话。"
        case CoreBridgeError.connect(_): return "连接启动失败，请检查配置后重试。"
        case CoreBridgeError.invalidUpstreamCommit(_): return "RustDesk Core 版本不匹配。"
        default: return "连接配置无效或本地组件不可用。"
        }
    }

    static func openKeyboardPrivacySettings() {
        let alert = NSAlert()
        alert.messageText = "允许独占键盘"
        alert.informativeText = "独占键盘需要“辅助功能”和“输入监控”两项权限。授权后无需保存密码；使用 ⌃⌥⇧Esc 可随时退出独占。"
        alert.addButton(withTitle: "打开辅助功能")
        alert.addButton(withTitle: "打开输入监控")
        alert.addButton(withTitle: "取消")
        let destination: String
        switch alert.runModal() {
        case .alertFirstButtonReturn: destination = "Privacy_Accessibility"
        case .alertSecondButtonReturn: destination = "Privacy_ListenEvent"
        default: return
        }
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(destination)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func openSystemPermissionSettings(_ kind: HomeSystemPermissionKind) {
        let destination: String
        switch kind {
        case .screenRecording: destination = "Privacy_ScreenCapture"
        case .accessibility: destination = "Privacy_Accessibility"
        case .inputMonitoring: destination = "Privacy_ListenEvent"
        case .microphone: destination = "Privacy_Microphone"
        }
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(destination)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    static func isErrorState(_ state: CoreConnectionState) -> Bool {
        state == .passwordRequired || state == .authenticationFailed || state == .error
            || state == .disconnected
    }

    static func isTerminalState(_ state: CoreConnectionState) -> Bool {
        state == .passwordRequired || state == .authenticationFailed || state == .error
            || state == .disconnected
    }

    static func connectionStateText(_ event: CoreStateEvent) -> String {
        switch event.state {
        case .idle: return "等待连接"
        case .connecting: return "正在连接…"
        case .transportReady: return "安全传输已建立"
        case .authenticated: return "认证成功"
        case .streaming: return "实时画面"
        case .controlReady: return "远端控制已授权"
        case .passwordRequired: return "需要密码，请重新连接"
        case .authenticationFailed: return "认证失败，请检查密码"
        case .disconnected:
            return event.code == ViewerAutomaticRecoveryPolicy.noRetryTerminalCode
                ? "连接已结束，未自动重连" : "连接已断开"
        case .error:
            return event.code == ViewerAutomaticRecoveryPolicy.noRetryTerminalCode
                ? "连接已结束，未自动重连" : "连接发生错误，请检查网络与远端状态"
        }
    }
}
