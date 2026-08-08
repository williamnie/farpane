import Foundation

/// Couples one process-lifetime bootstrap authority to one started HostCore.
/// The bootstrap owner stays retained while Core is running and is released
/// only after Core teardown has been attempted.
public final class HostAgentOwnedCoreRuntime<BootstrapOwner: AnyObject>: @unchecked Sendable {
    private let stateLock = NSLock()
    private var runtime: HostAgentCoreRuntime?
    private var bootstrapOwner: BootstrapOwner?

    private init(
        bootstrapOwner: BootstrapOwner,
        runtime: HostAgentCoreRuntime
    ) {
        self.bootstrapOwner = bootstrapOwner
        self.runtime = runtime
    }

    deinit {
        try? stop(reason: .appExit)
    }

    /// Retains `bootstrapOwner` before invoking the synchronous Core factory.
    /// If the factory fails, no partially-owned runtime is returned.
    public static func start(
        bootstrapOwner: BootstrapOwner,
        startRuntime: (BootstrapOwner) throws -> HostAgentCoreRuntime
    ) throws -> HostAgentOwnedCoreRuntime<BootstrapOwner> {
        let runtime = try startRuntime(bootstrapOwner)
        return HostAgentOwnedCoreRuntime(
            bootstrapOwner: bootstrapOwner,
            runtime: runtime
        )
    }

    /// Claims both owned values exactly once, attempts Core teardown, then
    /// releases the Core runtime before releasing the bootstrap authority.
    public func stop(reason: HostStopReason) throws {
        var runtimeToRelease: HostAgentCoreRuntime?
        var bootstrapOwnerToRelease: BootstrapOwner?

        stateLock.lock()
        runtimeToRelease = runtime
        bootstrapOwnerToRelease = bootstrapOwner
        runtime = nil
        bootstrapOwner = nil
        stateLock.unlock()

        guard runtimeToRelease != nil || bootstrapOwnerToRelease != nil else {
            return
        }
        defer {
            runtimeToRelease = nil
            bootstrapOwnerToRelease = nil
        }
        try runtimeToRelease?.stop(reason: reason)
    }
}
