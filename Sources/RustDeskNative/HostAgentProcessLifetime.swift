import CoreBridge
import Foundation

/// Product lifetime owner returned only after HostAgent runtime startup has
/// succeeded. It retains the runtime until the one terminal stop attempt.
final class HostAgentProcessLifetime: @unchecked Sendable {
    private let gate: HostAgentProcessLifetimeGate<HostAgentProcessRuntime>

    init(
        runtime: HostAgentProcessRuntime,
        prepareTermination: @escaping () -> Void = {}
    ) {
        self.gate = HostAgentProcessLifetimeGate(
            runtime: runtime,
            prepareTermination: {
                runtime.invalidateXPCIdentity()
                prepareTermination()
            },
            stopRuntime: { runtime, reason in
                try runtime.stop(reason: reason)
            }
        )
    }

    @discardableResult
    func requestTermination(reason: HostStopReason) -> Bool {
        gate.requestTermination(reason: reason)
    }

    func waitUntilTerminated() -> HostAgentProcessTerminationOutcome {
        gate.waitUntilTerminated()
    }

    func copySnapshot() throws -> HostCoreSnapshot {
        try gate.withRunningRuntime { runtime in
            try runtime.copySnapshot()
        }
    }

    func beginSleep(epoch: UInt64) throws {
        try gate.withRunningRuntime { runtime in
            try runtime.beginSleep(epoch: epoch)
        }
    }

    func finishSleep(epoch: UInt64) throws {
        try gate.withRunningRuntime { runtime in
            try runtime.finishSleep(epoch: epoch)
        }
    }

    func resumeAfterWake(epoch: UInt64) throws {
        try gate.withRunningRuntime { runtime in
            try runtime.resumeAfterWake(epoch: epoch)
        }
    }

    func recoverNetworkPath(generation: UInt64) throws {
        try gate.withRunningRuntime { runtime in
            try runtime.recoverNetworkPath(generation: generation)
        }
    }

    func bindXPCIdentity(
        hostInstanceID: String
    ) throws -> HostAgentXPCProcessIdentityBindResult {
        try gate.withRunningRuntime { runtime in
            runtime.bindXPCIdentity(hostInstanceID: hostInstanceID)
        }
    }

    func xpcIdentitySnapshot() throws -> HostAgentXPCProcessIdentityState {
        try gate.withRunningRuntime { runtime in
            runtime.xpcIdentitySnapshot()
        }
    }

    func invalidateXPCIdentity() throws {
        try gate.withRunningRuntime { runtime in
            runtime.invalidateXPCIdentity()
        }
    }

    func activateXPCListener() throws -> Bool {
        try gate.withRunningRuntime { runtime in
            runtime.activateXPCListener()
        }
    }

    func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        try gate.withRunningRuntime { runtime in
            try runtime.setMediaCapabilities(
                hostInstanceID: hostInstanceID,
                capabilities: capabilities
            )
        }
    }

    func submit(accessUnit: HostEncodedAccessUnit) throws {
        try gate.withRunningRuntime { runtime in
            try runtime.submit(accessUnit: accessUnit)
        }
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
        try gate.withRunningRuntime { runtime in
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
    }
}
