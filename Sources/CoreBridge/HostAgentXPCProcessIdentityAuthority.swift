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
    typealias BootIdentityGenerator = () -> String

    private let lock = NSLock()
    private let agentBuildID: String
    private let agentBootID: String
    private var state: HostAgentXPCProcessIdentityState = .waitingForHostInstance

    package static func makeProduct(agentBuildID: String) throws -> Self {
        try Self(
            agentBuildID: agentBuildID,
            generateAgentBootID: { UUID().uuidString.lowercased() }
        )
    }

    init(
        agentBuildID: String,
        generateAgentBootID: BootIdentityGenerator
    ) throws {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
            agentBuildID
        ) else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        let agentBootID = generateAgentBootID()
        guard HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID)
        else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
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
