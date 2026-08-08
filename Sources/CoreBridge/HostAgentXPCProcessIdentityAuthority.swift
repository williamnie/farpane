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
    package typealias InvalidationObserver = @Sendable () -> Void

    private let lock = NSLock()
    private let agentBuildID: String
    private let agentBootID: String
    private var state: HostAgentXPCProcessIdentityState = .waitingForHostInstance
    private var invalidationObserver: InvalidationObserver?
    private var invalidationDelivered = false

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

        if case .invalidated = state {
            lock.unlock()
            return .rejected(.invalidated)
        }
        guard HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID)
        else {
            let observer = transitionToInvalidatedLocked()
            lock.unlock()
            observer?()
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
                lock.unlock()
                return .bound
            } catch {
                let observer = transitionToInvalidatedLocked()
                lock.unlock()
                observer?()
                return .rejected(.invalidHostInstance)
            }
        case .ready(let identity):
            guard identity.hostInstanceID == hostInstanceID else {
                let observer = transitionToInvalidatedLocked()
                lock.unlock()
                observer?()
                return .rejected(.conflictingHostInstance)
            }
            lock.unlock()
            return .unchanged
        case .invalidated:
            lock.unlock()
            return .rejected(.invalidated)
        }
    }

    package func invalidate() {
        lock.lock()
        let observer = transitionToInvalidatedLocked()
        lock.unlock()
        observer?()
    }

    /// Installs the sole process-lifetime teardown observer. If identity was
    /// already invalidated, delivery occurs synchronously after releasing the
    /// authority lock. A second observer is rejected without replacement.
    @discardableResult
    package func installInvalidationObserver(
        _ observer: @escaping InvalidationObserver
    ) -> Bool {
        lock.lock()
        guard invalidationObserver == nil else {
            lock.unlock()
            return false
        }
        invalidationObserver = observer
        let shouldDeliver: Bool
        if case .invalidated = state, !invalidationDelivered {
            invalidationDelivered = true
            shouldDeliver = true
        } else {
            shouldDeliver = false
        }
        lock.unlock()
        if shouldDeliver { observer() }
        return true
    }

    /// Serializes a connection's handshake-only configuration and resume with
    /// identity invalidation. The body must not re-enter this authority.
    package func withReadyIdentityForAdmission<T>(
        _ body: (HostAgentXPCWireAgentIdentity) -> T
    ) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard case .ready(let identity) = state else { return nil }
        return body(identity)
    }

    package func snapshot() -> HostAgentXPCProcessIdentityState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    private func transitionToInvalidatedLocked() -> InvalidationObserver? {
        state = .invalidated
        guard !invalidationDelivered, let invalidationObserver else {
            return nil
        }
        invalidationDelivered = true
        return invalidationObserver
    }
}
