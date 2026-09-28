import AppKit
import ConnectionCatalog

struct HomeDeviceItem: Equatable {
    let device: SavedDevice
    let hasSavedPassword: Bool
}

enum HomeSystemPermissionKind: CaseIterable, Hashable {
    case screenRecording
    case accessibility
    case inputMonitoring
    case microphone

    var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .accessibility: return "辅助功能"
        case .inputMonitoring: return "输入监控"
        case .microphone: return "麦克风"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "允许远端看到本机画面"
        case .accessibility: return "允许远端控制鼠标和键盘"
        case .inputMonitoring: return "接收完整键盘事件与系统快捷键"
        case .microphone: return "仅在开启远程音频时需要"
        }
    }

    var symbolName: String {
        switch self {
        case .screenRecording: return "rectangle.inset.filled.and.person.filled"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
        case .microphone: return "mic"
        }
    }

    var isRequired: Bool { self != .microphone }
}

enum HomeSystemPermissionState: Equatable {
    case granted
    case notDetermined
    case denied
    case restricted

    var isGranted: Bool { self == .granted }

    var statusText: String {
        switch self {
        case .granted: return "已授权"
        case .notDetermined: return "待授权"
        case .denied: return "未授权"
        case .restricted: return "受系统限制"
        }
    }
}

struct HomeSystemPermissionSnapshot: Equatable {
    var screenRecording: HomeSystemPermissionState
    var accessibility: HomeSystemPermissionState
    var inputMonitoring: HomeSystemPermissionState
    var microphone: HomeSystemPermissionState

    static let unknown = HomeSystemPermissionSnapshot(
        screenRecording: .notDetermined, accessibility: .notDetermined,
        inputMonitoring: .notDetermined, microphone: .notDetermined)

    subscript(_ kind: HomeSystemPermissionKind) -> HomeSystemPermissionState {
        switch kind {
        case .screenRecording: return screenRecording
        case .accessibility: return accessibility
        case .inputMonitoring: return inputMonitoring
        case .microphone: return microphone
        }
    }

    var requiredGrantedCount: Int {
        HomeSystemPermissionKind.allCases.filter { $0.isRequired && self[$0].isGranted }.count
    }

    var requiredCount: Int { HomeSystemPermissionKind.allCases.filter(\.isRequired).count }
}

struct HostApprovalHomeSnapshot: Equatable {
    var connectionID: String
    var remoteIdentityText: String
    var contextText: String
    var capabilityText: String
    var expiryText: String
    var isResolving: Bool
    var enabledActions: Set<HostApprovalHomeAction>
}

enum HostApprovalHomeAction: Equatable, Hashable {
    case approve
    case reject
}

enum HostSessionHomeAction: Equatable, Hashable {
    case disableKeyboardAndMouse
    case disableClipboardRead
    case disableClipboardWrite
    case disableClipboard
    case disableSystemAudio
    case disconnect
}

struct HostActiveSessionHomeSnapshot: Equatable {
    var connectionID: String
    var remoteIdentityText: String
    var contextText: String
    var capabilityText: String
    var canDisableKeyboardAndMouse: Bool
    var canDisableClipboardRead: Bool
    var canDisableClipboardWrite: Bool
    var canDisableClipboard: Bool
    var canDisableSystemAudio: Bool
    var pendingAction: HostSessionHomeAction?
    var enabledActions: Set<HostSessionHomeAction>
}

struct HostCommandRetryHomeSnapshot: Equatable {
    var connectionID: String
    var title: String
}

struct HostHomeSnapshot: Equatable {
    var isEnabled: Bool
    var isControlEnabled: Bool
    var isRunning: Bool
    var isReady: Bool
    var allowsHostCommands: Bool
    var isStreaming: Bool
    var clipboardReadEnabled: Bool
    var clipboardWriteEnabled: Bool
    var clipboardRichTextReadEnabled: Bool = false
    var clipboardRichTextWriteEnabled: Bool = false
    var clipboardImageReadEnabled: Bool = false
    var clipboardImageWriteEnabled: Bool = false
    var allowsClipboardPolicyChange: Bool
    var fileTransferEnabled: Bool = false
    var fileTransferReceiveRootName: String = ""
    var allowsFileTransferPolicyChange: Bool = false
    var audioEnabled: Bool = false
    var audioInputDeviceNames: [String] = []
    var audioInputDeviceName: String?
    var audioInputDeviceAvailable: Bool = true
    var microphoneAuthorizationText: String = "系统音频使用屏幕录制权限；不需要麦克风权限"
    var allowsAudioPolicyChange: Bool = false
    var statusText: String
    var localID: String
    var temporaryPassword: String
    var localPermanentPasswordSet: Bool
    var effectivePermanentPasswordSet: Bool
    var usingPresetPassword: Bool
    var permanentPasswordChangeAllowed: Bool
    var pendingApproval: HostApprovalHomeSnapshot?
    var activeSession: HostActiveSessionHomeSnapshot?
    var commandRetry: HostCommandRetryHomeSnapshot?
    var mediaDiagnosticText: String
    var errorText: String
}

struct HomeSnapshot: Equatable {
    var server: ServerConfiguration?
    var devices: [HomeDeviceItem]
    var statusText: String
    var errorText: String
    var connectingPeerID: String?
    var viewerAudioOptIn: Bool = false
    var permissions: HomeSystemPermissionSnapshot = .unknown
    var host: HostHomeSnapshot
}

enum HomeDeviceAction {
    case connect
    case sendFiles
    case toggleFavorite
    case rename
    case updatePassword
    case deletePassword
    case deleteDevice
}

enum HomePage: String, CaseIterable {
    case connections
    case permissions
    case sharing

    var title: String {
        switch self {
        case .connections: return "设备"
        case .permissions: return "授权与安全"
        case .sharing: return "共享设置"
        }
    }

    var symbolName: String {
        switch self {
        case .connections: return "display.2"
        case .permissions: return "checkmark.shield"
        case .sharing: return "slider.horizontal.3"
        }
    }
}

enum HomePalette {
    static let accent = NSColor(calibratedRed: 0.41, green: 0.97, blue: 0.76, alpha: 1)
    static let panel = NSColor(calibratedRed: 0.082, green: 0.102, blue: 0.129, alpha: 1)
    static let panelHover = NSColor(calibratedRed: 0.102, green: 0.129, blue: 0.165, alpha: 1)
    /// accent 上的深色文字
    static let inkOnAccent = NSColor(calibratedRed: 0.024, green: 0.137, blue: 0.102, alpha: 1)
}
