import Foundation

public enum HostApplicationLifecyclePolicy {
    /// Closing the product window must not tear down an active in-process Host.
    /// Explicit application termination still runs the normal Host shutdown path.
    public static func shouldTerminateAfterLastWindowClosed(
        hostRuntimeActive: Bool
    ) -> Bool {
        !hostRuntimeActive
    }
}

public struct HostSessionIndicatorPresentation: Equatable, Sendable {
    public let connectionID: String
    public let title: String
    public let remoteIdentityText: String
    public let disconnectTitle: String
    public let disconnectEnabled: Bool
}

/// Produces the global active-session indicator from the same exact-session
/// snapshot authority used by the in-window controls. Invalid or ambiguous
/// inputs fail closed so a stale menu can never manufacture a control target.
public enum HostSessionIndicatorPolicy {
    public static func presentation(
        connectionID: String?,
        remoteID: String,
        remoteName: String,
        disconnectInFlight: Bool
    ) -> HostSessionIndicatorPresentation? {
        guard let connectionID,
              valid(connectionID, maximumUTF8Bytes: 128, allowEmpty: false),
              valid(remoteID, maximumUTF8Bytes: 256, allowEmpty: false),
              valid(remoteName, maximumUTF8Bytes: 256, allowEmpty: true)
        else { return nil }

        let identityText = remoteName.isEmpty
            ? "对方声明（未经验证）：\(remoteID)"
            : "对方声明（未经验证）：\(remoteName) · ID \(remoteID)"
        return HostSessionIndicatorPresentation(
            connectionID: connectionID,
            title: "FarPane 正在共享屏幕",
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
