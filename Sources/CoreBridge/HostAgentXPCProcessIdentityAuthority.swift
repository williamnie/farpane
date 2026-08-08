import Foundation

package enum HostAgentXPCProcessIdentityBindRejection: Equatable, Sendable {
    case invalidHostInstance
    case conflictingHostInstance
    case invalidated
}

package enum HostAgentXPCProcessIdentityBindResult: Equatable, Sendable {
    case bound
    case unchanged
    case rejected(HostAgentXPCProcessIdentityBindRejection)
}

package enum HostAgentXPCProcessIdentityState: Equatable, Sendable {
    case waitingForHostInstance
    case ready(HostAgentXPCWireAgentIdentity)
    case invalidated
}

/// Owns the Agent boot identity once per process composition and binds it to
/// exactly one authoritative Host instance. Any identity contradiction is
/// terminal so a later IPC owner cannot handshake under ambiguous identity.
package final class HostAgentXPCProcessIdentityAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private let agentBuildID: String
    private let agentBootID: String
    private var state: HostAgentXPCProcessIdentityState = .waitingForHostInstance

    package static func makeProduct(
        agentBuildID: String,
        agentBootID: String
    ) throws -> Self {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
            agentBuildID
        ),
            HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID)
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        return Self(agentBuildID: agentBuildID, agentBootID: agentBootID)
    }

    private init(agentBuildID: String, agentBootID: String) {
        self.agentBuildID = agentBuildID
        self.agentBootID = agentBootID
    }

    package func bind(
        hostInstanceID: String
    ) -> HostAgentXPCProcessIdentityBindResult {
        lock.lock()
        defer { lock.unlock() }

        if case .invalidated = state {
            return .rejected(.invalidated)
        }
        guard HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID)
        else {
            state = .invalidated
            return .rejected(.invalidHostInstance)
        }
        switch state {
        case .waitingForHostInstance:
            do {
                state = .ready(try HostAgentXPCWireAgentIdentity(
                    agentBuildID: agentBuildID,
                    hostInstanceID: hostInstanceID,
                    agentBootID: agentBootID
                ))
                return .bound
            } catch {
                state = .invalidated
                return .rejected(.invalidHostInstance)
            }
        case .ready(let identity):
            guard identity.hostInstanceID == hostInstanceID else {
                state = .invalidated
                return .rejected(.conflictingHostInstance)
            }
            return .unchanged
        case .invalidated:
            return .rejected(.invalidated)
        }
    }

    package func invalidate() {
        lock.lock()
        state = .invalidated
        lock.unlock()
    }

    package func snapshot() -> HostAgentXPCProcessIdentityState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }
}
