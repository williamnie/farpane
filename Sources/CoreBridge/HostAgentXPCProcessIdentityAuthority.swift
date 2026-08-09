import CryptoKit
import Darwin
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
    private let agentProcessIdentity: HostAgentXPCWireAgentProcessIdentity
    private var state: HostAgentXPCProcessIdentityState = .waitingForHostInstance
    private var invalidationObserver: InvalidationObserver?
    private var invalidationDelivered = false

    package static func makeProduct(
        agentBuildID: String,
        agentBootID: String
    ) throws -> Self {
        guard let processIdentity = currentProcessIdentity(
            agentBuildID: agentBuildID,
            agentBootID: agentBootID
        ) else {
            throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
        }
        return Self(agentProcessIdentity: processIdentity)
    }

    private init(agentProcessIdentity: HostAgentXPCWireAgentProcessIdentity) {
        self.agentProcessIdentity = agentProcessIdentity
    }

    package func agentProcessIdentitySnapshot()
        -> HostAgentXPCWireAgentProcessIdentity?
    {
        lock.lock()
        defer { lock.unlock() }
        if case .invalidated = state { return nil }
        return agentProcessIdentity
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
                state = .ready(
                    try agentProcessIdentity.bind(
                        hostInstanceID: hostInstanceID
                    )
                )
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

    /// Serializes authenticated service configuration/resume with identity
    /// invalidation. The body must not re-enter this authority.
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

    private static func currentProcessIdentity(
        agentBuildID: String,
        agentBootID: String
    ) -> HostAgentXPCWireAgentProcessIdentity? {
        let processID = getpid()
        guard processID > 1 else { return nil }

        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let copiedSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processID,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                expectedSize
            )
        }
        guard copiedSize == expectedSize,
              info.pbi_pid == UInt32(processID),
              info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000
        else { return nil }

        let rawProcessStartIdentity =
            "pid=\(processID);sec=\(info.pbi_start_tvsec);"
            + "usec=\(info.pbi_start_tvusec)"
        var hasher = SHA256()
        hasher.update(data: Data(
            "farpane.v1-concurrency.process-start.v1".utf8
        ))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(rawProcessStartIdentity.utf8))
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()

        return try? HostAgentXPCWireAgentProcessIdentity(
            agentBuildID: agentBuildID,
            agentBootID: agentBootID,
            agentProcessID: processID,
            agentProcessStartIdentitySHA256: digest
        )
    }
}
