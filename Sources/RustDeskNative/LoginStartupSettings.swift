import Foundation
import ServiceManagement

struct LoginStartupPresentation {
    let isEnabled: Bool
    let canChange: Bool
    let needsApproval: Bool
    let message: String
}

/// 以系统登录项为唯一状态来源，不另外保存一个可能失真的偏好。
final class LoginStartupSettings {
    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private var currentStatus: SMAppService.Status
    private var errorText = ""

    init(
        status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        currentStatus = status()
    }

    func refresh() { currentStatus = status() }

    func presentation() -> LoginStartupPresentation {
        let value = currentStatus
        let message: String
        switch value {
        case .enabled: message = "已开启：下次登录 Mac 后自动打开 FarPane。"
        case .notRegistered: message = "未开启：重启并登录后需要手动打开 FarPane。"
        case .requiresApproval: message = "等待系统允许，请在“登录项与扩展”中允许 FarPane。"
        case .notFound: message = "请先将 FarPane 安装到“应用程序”，再设置开机自启。"
        @unknown default: message = "无法确认系统登录项状态，请在系统设置中检查。"
        }
        return LoginStartupPresentation(
            isEnabled: value == .enabled || value == .requiresApproval,
            canChange: value == .enabled || value == .notRegistered || value == .requiresApproval,
            needsApproval: value == .requiresApproval,
            message: errorText.isEmpty ? message : "\(errorText)\n\(message)")
    }

    func setEnabled(_ enabled: Bool) {
        errorText = ""
        refresh()
        let before = presentation()
        guard before.canChange else { return }
        guard enabled != before.isEnabled else { return }
        do {
            if enabled { try register() } else { try unregister() }
            refresh()
            if presentation().isEnabled != enabled { errorText = "系统尚未应用此更改，请重试或检查系统登录项。" }
        } catch {
            refresh()
            errorText = "更改开机自启失败，请重试或检查系统登录项。"
        }
    }
}
