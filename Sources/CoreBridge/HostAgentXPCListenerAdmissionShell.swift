import Foundation

package struct HostAgentXPCListenerAdmissionSnapshot: Equatable, Sendable {
    package let connectionAttemptCount: UInt64
    package let rejectedPeerIdentityCount: UInt64
    package let rejectedHandshakeUnavailableCount: UInt64
    package let acceptedHandshakeConnectionCount: UInt64
    package let activeHandshakeConnectionCount: UInt64
    package let closedHandshakeConnectionCount: UInt64
    package let listenerActivated: Bool
    package let cancelled: Bool

    package init(
        connectionAttemptCount: UInt64,
        rejectedPeerIdentityCount: UInt64,
        rejectedHandshakeUnavailableCount: UInt64,
        acceptedHandshakeConnectionCount: UInt64,
        activeHandshakeConnectionCount: UInt64,
        closedHandshakeConnectionCount: UInt64,
        listenerActivated: Bool,
        cancelled: Bool
    ) {
        self.connectionAttemptCount = connectionAttemptCount
        self.rejectedPeerIdentityCount = rejectedPeerIdentityCount
        self.rejectedHandshakeUnavailableCount =
            rejectedHandshakeUnavailableCount
        self.acceptedHandshakeConnectionCount =
            acceptedHandshakeConnectionCount
        self.activeHandshakeConnectionCount =
            activeHandshakeConnectionCount
        self.closedHandshakeConnectionCount = closedHandshakeConnectionCount
        self.listenerActivated = listenerActivated
        self.cancelled = cancelled
    }
}

/// Owns the signed Mach-service listener and its first delegate boundary.
/// Only an identity-eligible peer admitted under the ready process identity can
/// receive the fixed handshake-only service. Listener activation remains a
/// separate process-composition responsibility.
package final class HostAgentXPCListenerAdmissionShell:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    package static let maximumActiveHandshakeConnectionCount = 8

    typealias ConnectionAssessor = (NSXPCConnection)
        -> HostAgentXPCPeerAdmissionStatus
    typealias ConnectionLifecycleHandler = @Sendable () -> Void
    struct ConnectionLifecycleHandlers: Sendable {
        let onInterruption: ConnectionLifecycleHandler
        let onInvalidation: ConnectionLifecycleHandler
    }
    typealias ConnectionConfigurator = (
        NSXPCConnection,
        NSXPCInterface,
        HostAgentXPCHandshakeHandler,
        ConnectionLifecycleHandlers
    ) -> Void
    typealias ConnectionAction = (NSXPCConnection) -> Void
    typealias ListenerAction = (NSXPCListener) -> Void

    private enum ConnectionEndReason: Equatable, Sendable {
        case interrupted
        case invalidated
    }

    private enum ListenerState: Equatable, Sendable {
        case inactive
        case activating
        case active
        case cancelled
    }

    private let lock = NSCondition()
    private let listener: NSXPCListener
    private let identityAuthority: HostAgentXPCProcessIdentityAuthority
    private let assessConnection: ConnectionAssessor
    private let nowUnixMilliseconds: HostAgentXPCHandshakeHandler.Clock
    private let configureConnection: ConnectionConfigurator
    private let resumeConnection: ConnectionAction
    private let invalidateConnection: ConnectionAction
    private let activateListener: ListenerAction
    private let invalidateListener: ListenerAction
    private var connectionAttemptCount: UInt64 = 0
    private var rejectedPeerIdentityCount: UInt64 = 0
    private var rejectedHandshakeUnavailableCount: UInt64 = 0
    private var acceptedHandshakeConnectionCount: UInt64 = 0
    private var closedHandshakeConnectionCount: UInt64 = 0
    private var activeConnections: [ObjectIdentifier: NSXPCConnection] = [:]
    private var listenerState: ListenerState = .inactive
    private var cancelled = false

    package static func makeProductShell(
        identityAuthority: HostAgentXPCProcessIdentityAuthority
    )
        -> HostAgentXPCListenerAdmissionShell
    {
        let listener = HostAgentXPCListenerFactory.makeListener()
        return HostAgentXPCListenerAdmissionShell(
            listener: listener,
            identityAuthority: identityAuthority,
            assessConnection: HostAgentXPCPeerAdmissionGate.assess,
            nowUnixMilliseconds: productClock,
            configureConnection: configureProductConnection,
            resumeConnection: { connection in connection.resume() },
            invalidateConnection: { connection in connection.invalidate() },
            activateListener: { listener in listener.activate() },
            invalidateListener: { listener in listener.invalidate() }
        )
    }

    init(
        listener: NSXPCListener,
        identityAuthority: HostAgentXPCProcessIdentityAuthority,
        assessConnection: @escaping ConnectionAssessor,
        nowUnixMilliseconds: @escaping HostAgentXPCHandshakeHandler.Clock,
        configureConnection: @escaping ConnectionConfigurator,
        resumeConnection: @escaping ConnectionAction,
        invalidateConnection: @escaping ConnectionAction,
        activateListener: @escaping ListenerAction,
        invalidateListener: @escaping ListenerAction
    ) {
        self.listener = listener
        self.identityAuthority = identityAuthority
        self.assessConnection = assessConnection
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.configureConnection = configureConnection
        self.resumeConnection = resumeConnection
        self.invalidateConnection = invalidateConnection
        self.activateListener = activateListener
        self.invalidateListener = invalidateListener
        super.init()
        listener.delegate = self
        let observerInstalled = identityAuthority.installInvalidationObserver {
            [weak self] in
            self?.cancel()
        }
        if !observerInstalled { cancel() }
    }

    deinit {
        cancel()
    }

    package func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard listener === self.listener else {
            recordAttempt(rejectedPeerIdentity: true)
            return false
        }
        recordAttempt(rejectedPeerIdentity: false)
        let admission = assessConnection(newConnection)
        guard admission == .eligible else {
            recordRejectedPeerIdentity()
            return false
        }

        let admitted = identityAuthority.withReadyIdentityForAdmission {
            [self] identity in
            configureAndResume(
                newConnection,
                identity: identity
            )
        }
        guard admitted == true else {
            recordRejectedHandshakeUnavailable()
            return false
        }
        return true
    }

    /// One-shot activation is serialized with process identity invalidation.
    /// The fixed listener remains inactive until the identity is ready.
    @discardableResult
    package func activate() -> Bool {
        identityAuthority.withReadyIdentityForAdmission { [self] _ in
            activateWhileIdentityIsReady()
        } == true
    }

    /// Terminally rejects new admission and invalidates every accepted
    /// handshake-only connection. Safe for repeated and concurrent callers.
    package func cancel() {
        lock.lock()
        while listenerState == .activating {
            lock.wait()
        }
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let shouldInvalidateListener = listenerState == .active
        listenerState = .cancelled
        let connections = Array(activeConnections.values)
        activeConnections.removeAll(keepingCapacity: false)
        addSaturating(
            UInt64(connections.count),
            to: &closedHandshakeConnectionCount
        )
        lock.broadcast()
        lock.unlock()

        if shouldInvalidateListener {
            invalidateListener(listener)
        }
        for connection in connections {
            invalidateConnection(connection)
        }
    }

    package func snapshot() -> HostAgentXPCListenerAdmissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostAgentXPCListenerAdmissionSnapshot(
            connectionAttemptCount: connectionAttemptCount,
            rejectedPeerIdentityCount: rejectedPeerIdentityCount,
            rejectedHandshakeUnavailableCount:
                rejectedHandshakeUnavailableCount,
            acceptedHandshakeConnectionCount:
                acceptedHandshakeConnectionCount,
            activeHandshakeConnectionCount: UInt64(activeConnections.count),
            closedHandshakeConnectionCount: closedHandshakeConnectionCount,
            listenerActivated: listenerState == .active,
            cancelled: cancelled
        )
    }

    private func activateWhileIdentityIsReady() -> Bool {
        lock.lock()
        guard !cancelled, listenerState == .inactive else {
            lock.unlock()
            return false
        }
        listenerState = .activating
        lock.unlock()

        activateListener(listener)

        lock.lock()
        listenerState = .active
        lock.broadcast()
        lock.unlock()
        return true
    }

    private func configureAndResume(
        _ connection: NSXPCConnection,
        identity: HostAgentXPCWireAgentIdentity
    ) -> Bool {
        let identifier = ObjectIdentifier(connection)
        lock.lock()
        guard !cancelled,
              activeConnections.count
                < Self.maximumActiveHandshakeConnectionCount,
              activeConnections[identifier] == nil
        else {
            lock.unlock()
            return false
        }
        activeConnections[identifier] = connection
        lock.unlock()

        let interface = HostAgentXPCHandshakeInterfaceFactory.makeInterface()
        let handler = HostAgentXPCHandshakeHandler(
            identity: identity,
            nowUnixMilliseconds: nowUnixMilliseconds
        )
        configureConnection(
            connection,
            interface,
            handler,
            ConnectionLifecycleHandlers(
                onInterruption: { [weak self] in
                    self?.connectionDidEnd(
                        identifier,
                        reason: .interrupted
                    )
                },
                onInvalidation: { [weak self] in
                    self?.connectionDidEnd(
                        identifier,
                        reason: .invalidated
                    )
                }
            )
        )

        lock.lock()
        guard !cancelled,
              activeConnections[identifier] === connection
        else {
            lock.unlock()
            return false
        }
        incrementSaturating(&acceptedHandshakeConnectionCount)
        lock.unlock()

        resumeConnection(connection)
        return true
    }

    private func connectionDidEnd(
        _ identifier: ObjectIdentifier,
        reason: ConnectionEndReason
    ) {
        lock.lock()
        guard let connection = activeConnections.removeValue(
            forKey: identifier
        ) else {
            lock.unlock()
            return
        }
        incrementSaturating(&closedHandshakeConnectionCount)
        lock.unlock()

        if reason == .interrupted {
            invalidateConnection(connection)
        }
    }

    private func recordAttempt(rejectedPeerIdentity: Bool) {
        lock.lock()
        incrementSaturating(&connectionAttemptCount)
        if rejectedPeerIdentity {
            incrementSaturating(&rejectedPeerIdentityCount)
        }
        lock.unlock()
    }

    private func recordRejectedPeerIdentity() {
        lock.lock()
        incrementSaturating(&rejectedPeerIdentityCount)
        lock.unlock()
    }

    private func recordRejectedHandshakeUnavailable() {
        lock.lock()
        incrementSaturating(&rejectedHandshakeUnavailableCount)
        lock.unlock()
    }

    private static let productClock: HostAgentXPCHandshakeHandler.Clock = {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= 9_007_199_254_740_991
        else { return 0 }
        return UInt64(milliseconds.rounded(.towardZero))
    }

    private static func configureProductConnection(
        _ connection: NSXPCConnection,
        _ interface: NSXPCInterface,
        _ handler: HostAgentXPCHandshakeHandler,
        _ lifecycle: ConnectionLifecycleHandlers
    ) {
        connection.exportedInterface = interface
        connection.exportedObject = handler
        connection.interruptionHandler = lifecycle.onInterruption
        connection.invalidationHandler = lifecycle.onInvalidation
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }

    private func addSaturating(_ addition: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(addition)
        value = overflow ? UInt64.max : sum
    }
}
