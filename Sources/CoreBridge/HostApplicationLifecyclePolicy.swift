import CoreFoundation
import CoreGraphics
import Foundation

public enum HostApplicationLifecyclePolicy {
    /// Closing the product window only hides the UI. Explicit application
    /// termination (for example Command-Q) still runs the normal shutdown path.
    public static func shouldTerminateAfterLastWindowClosed(
        hostRuntimeActive _: Bool
    ) -> Bool {
        false
    }
}

public enum ProductWindowTransitionPolicy {
    /// Replacing a full-screen window's content must preserve its current
    /// content size. Calling `setContentSize` during the transition leaves the
    /// replacement viewer at its old windowed dimensions inside full screen.
    public static func shouldResetWindowedContentSize(
        isFullScreen: Bool
    ) -> Bool {
        !isFullScreen
    }
}

public struct HostSessionIndicatorPresentation: Equatable, Sendable {
    public let connectionID: String
    public let title: String
    public let remoteIdentityText: String
    public let disconnectTitle: String
    public let disconnectEnabled: Bool
}

public struct HostSessionInputPresentation: Equatable, Sendable {
    public let overallStatusText: String
    public let detailText: String?
    public let statusItemTitle: String
}

public enum HostSessionInputPresentationPolicy {
    public static func presentation(
        availability: HostSessionInputAvailability,
        unavailableReason: HostSessionInputUnavailableReason?
    ) -> HostSessionInputPresentation? {
        switch (availability, unavailableReason) {
        case (.available, nil):
            return HostSessionInputPresentation(
                overallStatusText: "远程会话进行中",
                detailText: nil,
                statusItemTitle: "FarPane 正在共享屏幕"
            )
        case (.disabled, .localPolicyDisabled):
            return HostSessionInputPresentation(
                overallStatusText: "远程会话进行中",
                detailText: "键盘与鼠标已由本机停用",
                statusItemTitle: "FarPane 正在共享屏幕"
            )
        case (.disabled, .remoteDisabled):
            return HostSessionInputPresentation(
                overallStatusText: "远程会话进行中",
                detailText: "键盘与鼠标已由控制端停用",
                statusItemTitle: "FarPane 正在共享屏幕"
            )
        case (.limited, .accessibilityDenied):
            return HostSessionInputPresentation(
                overallStatusText: "远程会话受限：键鼠辅助功能权限不可用",
                detailText: "键盘与鼠标已暂停：重新授权后，请在本机重新启用键鼠控制",
                statusItemTitle: "FarPane 远程会话受限"
            )
        case (.limited, .sessionUnavailable):
            return HostSessionInputPresentation(
                overallStatusText: "远程会话受限：当前 Mac 会话不可用",
                detailText: "键盘与鼠标已暂停：当前 Mac 处于锁屏、登录窗口或其他用户会话",
                statusItemTitle: "FarPane 远程会话受限"
            )
        default:
            return nil
        }
    }
}

/// Combines independent GUI-session and input authorities for all Host UI.
/// The decoded input tuple must be valid even when the Aqua-session boundary
/// overrides its presentation, so malformed state never manufactures a card.
public enum HostSessionPresentationPolicy {
    public static func presentation(
        activeAquaSessionAvailable: Bool,
        inputAvailability: HostSessionInputAvailability,
        inputUnavailableReason: HostSessionInputUnavailableReason?
    ) -> HostSessionInputPresentation? {
        guard let inputPresentation = HostSessionInputPresentationPolicy.presentation(
            availability: inputAvailability,
            unavailableReason: inputUnavailableReason
        ) else { return nil }
        guard activeAquaSessionAvailable else {
            return unavailableAquaPresentation()
        }
        return inputPresentation
    }

    /// Background Host presentation consumes the strict top-level tuple
    /// projected by Rust instead of consulting a second local Aqua authority.
    package static func presentation(
        sessionAvailability: HostSessionAvailability,
        sessionUnavailableReason: HostSessionUnavailableReason?,
        inputAvailability: HostSessionInputAvailability,
        inputUnavailableReason: HostSessionInputUnavailableReason?
    ) -> HostSessionInputPresentation? {
        guard let inputPresentation =
                HostSessionInputPresentationPolicy.presentation(
                    availability: inputAvailability,
                    unavailableReason: inputUnavailableReason
                )
        else { return nil }
        switch (sessionAvailability, sessionUnavailableReason) {
        case (.available, nil):
            guard inputUnavailableReason != .sessionUnavailable
            else { return nil }
            return inputPresentation
        case (.limited, .sessionUnavailable):
            guard inputAvailability == .limited,
                  inputUnavailableReason == .sessionUnavailable
            else { return nil }
            return unavailableAquaPresentation()
        default:
            return nil
        }
    }

    private static func unavailableAquaPresentation()
        -> HostSessionInputPresentation
    {
        HostSessionInputPresentation(
            overallStatusText: "远程会话受限：当前 Mac 会话不可用",
            detailText: "当前版本不支持在锁屏、登录窗口或其他用户会话中远程操作；画面采集已暂停，远程键盘与鼠标不可用",
            statusItemTitle: "FarPane 远程会话受限"
        )
    }
}

/// Mirrors the pinned Rust platform gate: only an unlocked, logged-in console
/// Aqua session may capture. The lock key is omitted by macOS while unlocked;
/// required flags and non-CFBoolean values fail closed.
public enum HostActiveAquaSessionPolicy {
    private static let onConsoleKey = "kCGSSessionOnConsoleKey"
    private static let loginDoneKey = "kCGSessionLoginDoneKey"
    private static let screenLockedKey = "CGSSessionScreenIsLocked"

    public static func isAvailable(
        onConsole: Bool?,
        loginDone: Bool?,
        screenLocked: Bool?
    ) -> Bool {
        onConsole == true && loginDone == true && screenLocked != true
    }

    public static func isAvailable(sessionDictionary: [String: Any]) -> Bool {
        let screenLocked: Bool?
        if let value = sessionDictionary[screenLockedKey] {
            guard let parsed = strictBoolean(value) else { return false }
            screenLocked = parsed
        } else {
            screenLocked = false
        }
        return isAvailable(
            onConsole: strictBoolean(sessionDictionary[onConsoleKey]),
            loginDone: strictBoolean(sessionDictionary[loginDoneKey]),
            screenLocked: screenLocked
        )
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }
}

public enum HostActiveAquaSessionAuthority {
    public static func currentSessionIsAvailable() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        else { return false }
        return HostActiveAquaSessionPolicy.isAvailable(sessionDictionary: dictionary)
    }
}

/// Produces the global active-session indicator from the same exact-session
/// snapshot authority used by the in-window controls. Invalid or ambiguous
/// inputs fail closed so a stale menu can never manufacture a control target.
public enum HostSessionIndicatorPolicy {
    public static func presentation(
        connectionID: String?,
        remoteID: String,
        remoteName: String,
        activeAquaSessionAvailable: Bool = true,
        inputAvailability: HostSessionInputAvailability = .available,
        inputUnavailableReason: HostSessionInputUnavailableReason? = nil,
        disconnectInFlight: Bool
    ) -> HostSessionIndicatorPresentation? {
        guard let connectionID,
              valid(connectionID, maximumUTF8Bytes: 128, allowEmpty: false),
              valid(remoteID, maximumUTF8Bytes: 256, allowEmpty: false),
              valid(remoteName, maximumUTF8Bytes: 256, allowEmpty: true),
              let sessionPresentation = HostSessionPresentationPolicy.presentation(
                  activeAquaSessionAvailable: activeAquaSessionAvailable,
                  inputAvailability: inputAvailability,
                  inputUnavailableReason: inputUnavailableReason
              )
        else { return nil }

        let identityText = remoteName.isEmpty
            ? "对方声明（未经验证）：\(remoteID)"
            : "对方声明（未经验证）：\(remoteName) · ID \(remoteID)"
        return HostSessionIndicatorPresentation(
            connectionID: connectionID,
            title: sessionPresentation.statusItemTitle,
            remoteIdentityText: identityText,
            disconnectTitle: disconnectInFlight ? "正在断开…" : "断开连接",
            disconnectEnabled: !disconnectInFlight
        )
    }

    private static func valid(
        _ value: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool
    ) -> Bool {
        (allowEmpty || !value.isEmpty)
            && value.utf8.count <= maximumUTF8Bytes
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }
}
