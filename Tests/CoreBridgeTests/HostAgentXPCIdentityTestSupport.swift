@testable import CoreBridge

extension HostAgentXPCWireAgentIdentity {
    static func test(
        agentBuildID: String,
        hostInstanceID: String,
        agentBootID: String,
        agentProcessID: Int32 = 4_321,
        agentProcessStartIdentitySHA256: String =
            String(repeating: "a", count: 64)
    ) throws -> Self {
        try Self(
            agentBuildID: agentBuildID,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            agentProcessID: agentProcessID,
            agentProcessStartIdentitySHA256:
                agentProcessStartIdentitySHA256
        )
    }
}

extension HostAgentXPCSnapshotClientPeerIdentity {
    static func test(
        agentBuildID: String,
        hostInstanceID: String,
        agentBootID: String,
        agentProcessID: Int32 = 4_321,
        agentProcessStartIdentitySHA256: String =
            String(repeating: "a", count: 64)
    ) throws -> Self {
        try Self(
            agentBuildID: agentBuildID,
            hostInstanceID: hostInstanceID,
            agentBootID: agentBootID,
            agentProcessID: agentProcessID,
            agentProcessStartIdentitySHA256:
                agentProcessStartIdentitySHA256
        )
    }
}
