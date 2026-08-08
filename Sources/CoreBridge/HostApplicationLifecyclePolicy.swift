public enum HostApplicationLifecyclePolicy {
    /// Closing the product window must not tear down an active in-process Host.
    /// Explicit application termination still runs the normal Host shutdown path.
    public static func shouldTerminateAfterLastWindowClosed(
        hostRuntimeActive: Bool
    ) -> Bool {
        !hostRuntimeActive
    }
}
