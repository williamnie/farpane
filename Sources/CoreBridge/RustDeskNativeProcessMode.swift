public enum RustDeskNativeProcessMode: Equatable, Sendable {
    case application
    case hostAgent
    case unsupportedConnectionManager
}

/// Resolves the executable role without initializing AppKit. Legacy RustDesk
/// connection-manager roles are rejected before AppKit because FarPane owns
/// their presentation and lifecycle inside its native Host process.
public enum RustDeskNativeProcessModePolicy {
    public static func resolve(arguments: [String]) -> RustDeskNativeProcessMode {
        let roleArguments = Array(arguments.dropFirst())
        if roleArguments.contains(where: {
            $0 == "--cm" || $0 == "--cm-no-ui"
        }) {
            return .unsupportedConnectionManager
        }
        return roleArguments.contains("--host-agent") ? .hostAgent : .application
    }
}

public enum RustDeskNativeConnectionManagerRejectionPolicy {
    public static let exitCode: Int32 = 64
    public static let diagnostic =
        "FarPane connection-manager mode is unsupported.\n"
}
