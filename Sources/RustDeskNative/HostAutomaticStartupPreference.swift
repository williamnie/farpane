import CoreBridge
import Foundation

/// 自启动应用时仍尊重用户明确关闭被控端的选择；退出应用不改变此选择。
final class HostAutomaticStartupPreference {
    private static let key = "farpane.host.automaticStartupAllowed"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isAllowed: Bool { defaults.object(forKey: Self.key) as? Bool ?? true }

    func record(_ decision: HostAgentBackgroundProductRoutingDecision) {
        switch decision {
        case .enableAndRefresh: defaults.set(true, forKey: Self.key)
        case .disable: defaults.set(false, forKey: Self.key)
        case .noChange, .invalidCompletion: break
        }
    }
}
