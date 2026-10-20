import CoreBridge

enum ViewerMacOSShortcut: Int, CaseIterable {
    case launchpad
    case missionControl
    case desktop

    var title: String {
        switch self {
        case .launchpad: return "启动台"
        case .missionControl: return "调度中心"
        case .desktop: return "桌面"
        }
    }

    var symbolName: String {
        switch self {
        case .launchpad: return "square.grid.3x3"
        case .missionControl: return "rectangle.3.group"
        case .desktop: return "menubar.dock.rectangle"
        }
    }

    var key: CoreKey {
        switch self {
        case .launchpad: return .physical(131)
        case .missionControl: return .physical(160)
        case .desktop: return .physical(103)  // F11：显示桌面。
        }
    }
}
