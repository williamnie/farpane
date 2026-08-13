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

    /// Copies from the same Core owner while it is still protected from stop.
    public func copySnapshot() throws -> HostCoreSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runtime else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        return try runtime.copySnapshot()
    }

    public func beginSleep(epoch: UInt64) throws {
        try withRunningRuntime { runtime in
            try runtime.beginSleep(epoch: epoch)
        }
    }

    public func finishSleep(epoch: UInt64) throws {
        try withRunningRuntime { runtime in
            try runtime.finishSleep(epoch: epoch)
        }
    }

    public func resumeAfterWake(epoch: UInt64) throws {
        try withRunningRuntime { runtime in
            try runtime.resumeAfterWake(epoch: epoch)
        }
    }

    public func recoverNetworkPath(generation: UInt64) throws {
        try withRunningRuntime { runtime in
            try runtime.recoverNetworkPath(generation: generation)
        }
    }

    public func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runtime else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try runtime.setMediaCapabilities(
            hostInstanceID: hostInstanceID,
            capabilities: capabilities
        )
    }

    public func submit(accessUnit: HostEncodedAccessUnit) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runtime else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try runtime.submit(accessUnit: accessUnit)
    }

    public func reportEncoderState(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        codec: HostMediaCodec,
        hardwareAccelerated: Bool,
        softwareFallback: Bool,
        encoderID: String
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runtime else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try runtime.reportEncoderState(
            hostInstanceID: hostInstanceID,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            codec: codec,
            hardwareAccelerated: hardwareAccelerated,
            softwareFallback: softwareFallback,
            encoderID: encoderID
        )
    }

    package func submit(command: HostAgentCoreCommandSubmission) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runtime else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try runtime.submit(command: command)
    }

    package func performPasswordOperation(
        _ action: HostAgentXPCPasswordAction,
        secret: inout Data,
        requestID: String
    ) throws -> Data? {
        try withRunningRuntime { runtime in
            try runtime.performPasswordOperation(
                action,
                secret: &secret,
                requestID: requestID
            )
        }
    }

    private func withRunningRuntime<Value>(
        _ body: (HostAgentCoreRuntime) throws -> Value
    ) throws -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let runtime else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        return try body(runtime)
    }
}
