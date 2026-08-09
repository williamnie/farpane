import ConnectionCatalog
import CoreBridge
import Foundation

/// Product assembly boundary for the future `--host-agent` process. This is
/// deliberately not dispatched yet: snapshot-first/control IPC and the Agent
/// entry remain required before replacing the fail-closed mode gate.
final class HostAgentProcessRuntime: @unchecked Sendable {
    private enum CompositionError: Error {
        case commandOwnerBindingFailed
        case commandQueueDrainTimedOut
    }

    private let ownedRuntime: HostAgentOwnedCoreRuntime<HostAgentBootstrapContext>
    private let xpcIdentityAuthority: HostAgentXPCProcessIdentityAuthority
    private let commandOwner: HostAgentXPCCommandProcessOwner
    private let xpcAdmissionOwner: HostAgentXPCListenerAdmissionShell

    private init(
        ownedRuntime: HostAgentOwnedCoreRuntime<HostAgentBootstrapContext>,
        xpcIdentityAuthority: HostAgentXPCProcessIdentityAuthority,
        commandOwner: HostAgentXPCCommandProcessOwner,
        xpcAdmissionOwner: HostAgentXPCListenerAdmissionShell
    ) {
        self.ownedRuntime = ownedRuntime
        self.xpcIdentityAuthority = xpcIdentityAuthority
        self.commandOwner = commandOwner
        self.xpcAdmissionOwner = xpcAdmissionOwner
    }

    deinit {
        _ = commandOwner.cancelAndWait(timeout: .now())
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
        let commandOwner = try HostAgentXPCCommandProcessOwner(
            agentBuildID: bootstrapContext.leaseRecord.agentBuildID,
            agentBootID:
                bootstrapContext.leaseRecord.agentBootID.uuidString.lowercased(),
            eventState: eventState,
            nowUnixMilliseconds: productClock,
            onNonCommandEvent: onEvent,
            onInvalidationRequired: {
                xpcIdentityAuthority.invalidate()
            }
        )
        let ownedRuntime = try HostAgentOwnedCoreRuntime.start(
            bootstrapOwner: bootstrapContext
        ) { context in
            let libraryURL = try HostAgentBundledCoreLocator.locate()
            let client = try HostControlClient(
                libraryURL: libraryURL,
                eventQueue: eventQueue,
                onEvent: { event in
                    commandOwner.consumeCoreEvent(event)
                }
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
        guard commandOwner.bindRuntimeSubmission({ submission in
            do {
                try ownedRuntime.submit(command: submission)
                return .awaitingCoreResult
            } catch HostAgentCoreRuntimeAccessError.notRunning {
                return .failed(.coreUnavailable)
            } catch let error as HostControlError {
                if case .command = error {
                    return .rejected(.coreRejected)
                }
                return .failed(.coreFailure)
            } catch {
                return .failed(.coreFailure)
            }
        }) else {
            try? ownedRuntime.stop(reason: .error)
            throw CompositionError.commandOwnerBindingFailed
        }
        let xpcAdmissionOwner =
            HostAgentXPCListenerAdmissionShell.makeProductShell(
                identityAuthority: xpcIdentityAuthority,
                snapshotState: snapshotState,
                eventState: eventState,
                commandServiceProvider: { [weak commandOwner] in
                    commandOwner?.commandServiceSnapshot()
                }
            )
        return HostAgentProcessRuntime(
            ownedRuntime: ownedRuntime,
            xpcIdentityAuthority: xpcIdentityAuthority,
            commandOwner: commandOwner,
            xpcAdmissionOwner: xpcAdmissionOwner
        )
    }

    func stop(reason: HostStopReason) throws {
        let commandQueueDrained = commandOwner.cancelAndWait(
            timeout: .now() + 2
        )
        xpcIdentityAuthority.invalidate()
        try ownedRuntime.stop(reason: reason)
        guard commandQueueDrained else {
            throw CompositionError.commandQueueDrainTimedOut
        }
    }

    func bindXPCIdentity(
        hostInstanceID: String
    ) -> HostAgentXPCProcessIdentityBindResult {
        let commandResult = commandOwner.bindIdentity(
            hostInstanceID: hostInstanceID
        )
        guard commandResult == .bound || commandResult == .unchanged else {
            xpcIdentityAuthority.invalidate()
            return commandResult
        }
        let identityResult = xpcIdentityAuthority.bind(
            hostInstanceID: hostInstanceID
        )
        guard identityResult == .bound || identityResult == .unchanged else {
            commandOwner.invalidate()
            return identityResult
        }
        return identityResult
    }

    func xpcIdentitySnapshot() -> HostAgentXPCProcessIdentityState {
        xpcIdentityAuthority.snapshot()
    }

    func invalidateXPCIdentity() {
        _ = commandOwner.cancelAndWait(timeout: .now() + 2)
        xpcIdentityAuthority.invalidate()
    }

    func activateXPCListener() -> Bool {
        xpcAdmissionOwner.activate()
    }

    func copySnapshot() throws -> HostCoreSnapshot {
        try ownedRuntime.copySnapshot()
    }

    func beginSleep(epoch: UInt64) throws {
        try ownedRuntime.beginSleep(epoch: epoch)
    }

    func finishSleep(epoch: UInt64) throws {
        try ownedRuntime.finishSleep(epoch: epoch)
    }

    func resumeAfterWake(epoch: UInt64) throws {
        try ownedRuntime.resumeAfterWake(epoch: epoch)
    }

    func recoverNetworkPath(generation: UInt64) throws {
        try ownedRuntime.recoverNetworkPath(generation: generation)
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

    private static let productClock:
        HostAgentXPCCommandProcessOwner.Clock = {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= 9_007_199_254_740_991
        else { return 0 }
        return UInt64(milliseconds.rounded(.towardZero))
    }
}
