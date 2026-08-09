import Foundation

/// Minimal control surface needed by the HostAgent runtime owner. A conformer
/// must clean up any partially-created Host instance before `start` throws.
public protocol HostAgentCoreControlSurface: AnyObject {
    func setConfigRoot(appName: String, org: String) throws
    func start(configuration: HostServerConfiguration) throws
    func beginSleep(epoch: UInt64) throws
    func finishSleep(epoch: UInt64) throws
    func resumeAfterWake(epoch: UInt64) throws
    func recoverNetworkPath(generation: UInt64) throws
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
    func resolvePendingApproval(
        connectionID: String,
        decision: HostApprovalDecision,
        commandId: String
    ) throws
    func disableActiveSessionCapability(
        _ capability: HostSessionRevocableCapability,
        connectionID: String,
        commandId: String
    ) throws
    func disconnectSession(
        connectionID: String,
        commandId: String
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

    public func beginSleep(epoch: UInt64) throws {
        try withRunningClient { client in
            try client.beginSleep(epoch: epoch)
        }
    }

    public func finishSleep(epoch: UInt64) throws {
        try withRunningClient { client in
            try client.finishSleep(epoch: epoch)
        }
    }

    public func resumeAfterWake(epoch: UInt64) throws {
        try withRunningClient { client in
            try client.resumeAfterWake(epoch: epoch)
        }
    }

    public func recoverNetworkPath(generation: UInt64) throws {
        try withRunningClient { client in
            try client.recoverNetworkPath(generation: generation)
        }
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

    package func submit(command: HostAgentCoreCommandSubmission) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        switch command.action {
        case .resolveApproval(let decision):
            try client.resolvePendingApproval(
                connectionID: command.connectionID,
                decision: decision,
                commandId: command.commandID
            )
        case .disable(let capability):
            try client.disableActiveSessionCapability(
                capability,
                connectionID: command.connectionID,
                commandId: command.commandID
            )
        case .disconnect:
            try client.disconnectSession(
                connectionID: command.connectionID,
                commandId: command.commandID
            )
        }
    }

    private func withRunningClient<Value>(
        _ body: (any HostAgentCoreControlSurface) throws -> Value
    ) throws -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else {
            throw HostAgentCoreRuntimeAccessError.notRunning
        }
        return try body(client)
    }
}
