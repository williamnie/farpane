import Foundation

/// Minimal control surface needed by the HostAgent runtime owner. A conformer
/// must clean up any partially-created Host instance before `start` throws.
public protocol HostAgentCoreControlSurface: AnyObject {
    func setConfigRoot(appName: String, org: String) throws
    func start(configuration: HostServerConfiguration) throws
    func copySnapshot() throws -> HostCoreSnapshot
    func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws
    func submit(accessUnit: HostEncodedAccessUnit) throws
    func reportEncoderState(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        codec: HostMediaCodec,
        hardwareAccelerated: Bool,
        softwareFallback: Bool,
        encoderID: String
    ) throws
    func stop(reason: HostStopReason) throws
}

extension HostControlClient: HostAgentCoreControlSurface {}

public enum HostAgentCoreRuntimeAccessError: Error, Equatable {
    case notRunning
}

/// Owns one successfully started HostCore and enforces config-root-first
/// initialization. Loading/creating the concrete control surface and retaining
/// the higher-level bootstrap lease context remain caller responsibilities.
public final class HostAgentCoreRuntime: @unchecked Sendable {
    private let client: any HostAgentCoreControlSurface
    private let stateLock = NSLock()
    private var stopped = false

    private init(client: any HostAgentCoreControlSurface) {
        self.client = client
    }

    deinit {
        try? stop(reason: .appExit)
    }

    public static func start(
        client: any HostAgentCoreControlSurface,
        configAppName: String,
        configOrganization: String,
        serverConfiguration: HostServerConfiguration
    ) throws -> HostAgentCoreRuntime {
        try client.setConfigRoot(
            appName: configAppName,
            org: configOrganization
        )
        try client.start(configuration: serverConfiguration)
        return HostAgentCoreRuntime(client: client)
    }

    public func stop(reason: HostStopReason) throws {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()
        try client.stop(reason: reason)
    }

    public func copySnapshot() throws -> HostCoreSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        return try client.copySnapshot()
    }

    public func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try client.setMediaCapabilities(
            hostInstanceID: hostInstanceID,
            capabilities: capabilities
        )
    }

    public func submit(accessUnit: HostEncodedAccessUnit) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try client.submit(accessUnit: accessUnit)
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
        guard !stopped else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        try client.reportEncoderState(
            hostInstanceID: hostInstanceID,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            codec: codec,
            hardwareAccelerated: hardwareAccelerated,
            softwareFallback: softwareFallback,
            encoderID: encoderID
        )
    }
}
