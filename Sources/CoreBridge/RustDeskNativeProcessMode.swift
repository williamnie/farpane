public enum RustDeskNativeProcessMode: Equatable, Sendable {
    case application
    case hostAgent
}

/// Resolves the executable role without initializing AppKit. Only the exact
/// dedicated flag selects HostAgent so similarly named Viewer arguments never
/// change the process role accidentally.
public enum RustDeskNativeProcessModePolicy {
    public static func resolve(arguments: [String]) -> RustDeskNativeProcessMode {
        arguments.dropFirst().contains("--host-agent") ? .hostAgent : .application
    }
}
