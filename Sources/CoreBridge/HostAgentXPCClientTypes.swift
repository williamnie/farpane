import CoreBridgeShim
import Foundation

package enum HostAgentXPCSnapshotClientConfigurationError: Error, Equatable {
    case invalidAppBuildID
    case invalidPeerIdentity
}

package struct HostAgentXPCSnapshotClientPeerIdentity: Equatable, Sendable {
    package let agentBuildID: String
    package let hostInstanceID: String
    package let agentBootID: String
    package let agentProcessID: Int32
    package let agentProcessStartIdentitySHA256: String

    package init(
        agentBuildID: String, hostInstanceID: String, agentBootID: String, agentProcessID: Int32,
        agentProcessStartIdentitySHA256: String
    ) throws {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(agentBuildID),
            HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
            HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID),
            HostAgentXPCWireHandshakeContract.validAgentProcessID(agentProcessID),
            HostAgentXPCWireHandshakeContract.validLowercaseSHA256(agentProcessStartIdentitySHA256)
        else { throw HostAgentXPCSnapshotClientConfigurationError.invalidPeerIdentity }
        self.agentBuildID = agentBuildID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
        self.agentProcessID = agentProcessID
        self.agentProcessStartIdentitySHA256 = agentProcessStartIdentitySHA256
    }

    init(response: HostAgentXPCWireHandshakeResponse) throws {
        try self.init(
            agentBuildID: response.agentBuildID, hostInstanceID: response.hostInstanceID,
            agentBootID: response.agentBootID, agentProcessID: response.agentProcessID,
            agentProcessStartIdentitySHA256: response.agentProcessStartIdentitySHA256)
    }
}

package enum HostAgentXPCSnapshotClientIdentityTransition: Equatable, Sendable {
    case firstObservation
    case unchanged
    case replacedPrevious
}

package enum HostAgentXPCSnapshotClientResult: Equatable, Sendable {
    case ready(
        snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        identityTransition: HostAgentXPCSnapshotClientIdentityTransition)
    case incompatible
    case invalidResponse
    case disconnected
    case timedOut
    case cancelled
    case invalidState
}

package enum HostAgentXPCSnapshotClientEventResult: Equatable, Sendable {
    case events(HostAgentXPCWireEventCursorResponse)
    case resynchronized(
        snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse)
    case invalidResponse
    case disconnected
    case timedOut
    case cancelled
    case invalidState
}

/// A command observer receives one queued acceptance followed by exactly one
/// terminal outcome. `resultUnknown` and `resultTimedOut` are retryable with
/// the same command ID.
package enum HostAgentXPCSnapshotClientCommandResult: Equatable, Sendable {
    case accepted(HostAgentXPCWireCommandAcceptedResponse)
    case completed(HostAgentXPCWireCommandResult)
    case resultUnknown
    case invalidRequest
    case invalidResponse
    case disconnected
    case acceptanceTimedOut
    case resultTimedOut
    case cancelled
    case invalidState
}

package enum HostAgentXPCSnapshotClientCommandState: Equatable, Sendable {
    case idle
    case submitting(commandID: String)
    case awaitingResult(commandID: String)
}

package enum HostAgentXPCSnapshotClientPasswordResult: Equatable, Sendable {
    case completed(HostAgentXPCWirePasswordResponse, secret: Data?)
    case invalidRequest
    case invalidResponse
    case disconnected
    case timedOut
    case cancelled
    case invalidState
}

package enum HostAgentXPCSnapshotClientState: Equatable, Sendable {
    case idle
    case handshaking
    case fetchingSnapshot(HostAgentXPCSnapshotClientPeerIdentity)
    case deliveringSnapshot(HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64)
    case ready(HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64)
    case fetchingEvents(HostAgentXPCSnapshotClientPeerIdentity, afterEventID: UInt64)
    case refreshingSnapshot(HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64)
    case submittingCommand(
        HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64, commandID: String)
    case performingPasswordOperation(
        HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64, requestID: String)
    case incompatible
    case failed
    case disconnected
    case cancelled
}
