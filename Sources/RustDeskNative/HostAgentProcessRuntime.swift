import ConnectionCatalog
import CoreBridge
import Foundation

/// Product assembly boundary for the future `--host-agent` process. This is
/// deliberately not dispatched yet: snapshot-first/control IPC and the Agent
/// entry remain required before replacing the fail-closed mode gate.
final class HostAgentProcessRuntime: @unchecked Sendable {
    private let ownedRuntime: HostAgentOwnedCoreRuntime<HostAgentBootstrapContext>
    private let xpcIdentityAuthority: HostAgentXPCProcessIdentityAuthority
    private let xpcAdmissionOwner: HostAgentXPCListenerAdmissionShell

    private init(
        ownedRuntime: HostAgentOwnedCoreRuntime<HostAgentBootstrapContext>,
        xpcIdentityAuthority: HostAgentXPCProcessIdentityAuthority,
        xpcAdmissionOwner: HostAgentXPCListenerAdmissionShell
    ) {
        self.ownedRuntime = ownedRuntime
        self.xpcIdentityAuthority = xpcIdentityAuthority
        self.xpcAdmissionOwner = xpcAdmissionOwner
    }

    deinit {
        xpcIdentityAuthority.invalidate()
    }

    static func start(
        expectedAgentBuildID: String,
        eventState: HostAgentEventState,
        snapshotState: HostAgentSnapshotState,
        eventQueue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.events",
            qos: .userInitiated
        ),
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) throws -> HostAgentProcessRuntime {
        let bootstrapContext = try HostAgentBootstrapContext.prepare(
            expectedAgentBuildID: expectedAgentBuildID
        )
        let xpcIdentityAuthority = try
            HostAgentXPCProcessIdentityAuthority.makeProduct(
                agentBuildID: bootstrapContext.leaseRecord.agentBuildID,
                agentBootID:
                    bootstrapContext.leaseRecord.agentBootID.uuidString.lowercased()
            )
        let xpcAdmissionOwner =
            HostAgentXPCListenerAdmissionShell.makeProductShell(
                identityAuthority: xpcIdentityAuthority,
                snapshotState: snapshotState,
                eventState: eventState
            )
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
        return HostAgentProcessRuntime(
            ownedRuntime: ownedRuntime,
            xpcIdentityAuthority: xpcIdentityAuthority,
            xpcAdmissionOwner: xpcAdmissionOwner
        )
    }

    func stop(reason: HostStopReason) throws {
        xpcIdentityAuthority.invalidate()
        try ownedRuntime.stop(reason: reason)
    }

    func bindXPCIdentity(
        hostInstanceID: String
    ) -> HostAgentXPCProcessIdentityBindResult {
        xpcIdentityAuthority.bind(hostInstanceID: hostInstanceID)
    }

    func xpcIdentitySnapshot() -> HostAgentXPCProcessIdentityState {
        xpcIdentityAuthority.snapshot()
    }

    func invalidateXPCIdentity() {
        xpcIdentityAuthority.invalidate()
    }

    func activateXPCListener() -> Bool {
        xpcAdmissionOwner.activate()
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
