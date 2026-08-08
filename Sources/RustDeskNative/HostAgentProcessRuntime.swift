import ConnectionCatalog
import CoreBridge
import Foundation

/// Product assembly boundary for the future `--host-agent` process. This is
/// deliberately not dispatched yet: authenticated control IPC and the Agent
/// run loop remain required before replacing the fail-closed mode gate.
final class HostAgentProcessRuntime: @unchecked Sendable {
    private let ownedRuntime: HostAgentOwnedCoreRuntime<HostAgentBootstrapContext>

    private init(
        ownedRuntime: HostAgentOwnedCoreRuntime<HostAgentBootstrapContext>
    ) {
        self.ownedRuntime = ownedRuntime
    }

    static func start(
        eventQueue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.events",
            qos: .userInitiated
        ),
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) throws -> HostAgentProcessRuntime {
        let bootstrapContext = try HostAgentBootstrapContext.prepare()
        let ownedRuntime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: bootstrapContext
        ) { context in
            let libraryURL = try HostAgentBundledCoreLocator.locate()
            let client = try HostControlClient(
                libraryURL: libraryURL,
                eventQueue: eventQueue,
                onEvent: onEvent
            )
            let configuration = context.configuration
            return try HostAgentCoreRuntime.start(
                client: client,
                configAppName: configuration.hostConfigAppName,
                configOrganization: configuration.hostConfigOrganization,
                serverConfiguration: HostServerConfiguration(
                    rendezvousServer: configuration.rendezvousServer,
                    serverPublicKey: configuration.serverPublicKey
                )
            )
        }
        return HostAgentProcessRuntime(ownedRuntime: ownedRuntime)
    }

    func stop(reason: HostStopReason) throws {
        try ownedRuntime.stop(reason: reason)
    }

    func copySnapshot() throws -> HostCoreSnapshot {
        try ownedRuntime.copySnapshot()
    }

    func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        try ownedRuntime.setMediaCapabilities(
            hostInstanceID: hostInstanceID,
            capabilities: capabilities
        )
    }

    func submit(accessUnit: HostEncodedAccessUnit) throws {
        try ownedRuntime.submit(accessUnit: accessUnit)
    }

    func reportEncoderState(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        codec: HostMediaCodec,
        hardwareAccelerated: Bool,
        softwareFallback: Bool,
        encoderID: String
    ) throws {
        try ownedRuntime.reportEncoderState(
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
