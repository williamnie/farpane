import Foundation

package struct HostAgentXPCListenerAdmissionSnapshot: Equatable, Sendable {
    package let connectionAttemptCount: UInt64
    package let rejectedPeerIdentityCount: UInt64
    package let rejectedInterfaceUnavailableCount: UInt64

    package init(
        connectionAttemptCount: UInt64,
        rejectedPeerIdentityCount: UInt64,
        rejectedInterfaceUnavailableCount: UInt64
    ) {
        self.connectionAttemptCount = connectionAttemptCount
        self.rejectedPeerIdentityCount = rejectedPeerIdentityCount
        self.rejectedInterfaceUnavailableCount =
            rejectedInterfaceUnavailableCount
    }
}

/// Owns the signed Mach-service listener and its first delegate boundary.
/// Until a typed, versioned interface exists, every connection is rejected,
/// including peers that pass identity admission.
package final class HostAgentXPCListenerAdmissionShell:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    typealias ConnectionAssessor = (NSXPCConnection)
        -> HostAgentXPCPeerAdmissionStatus

    private let lock = NSLock()
    private let listener: NSXPCListener
    private let assessConnection: ConnectionAssessor
    private var connectionAttemptCount: UInt64 = 0
    private var rejectedPeerIdentityCount: UInt64 = 0
    private var rejectedInterfaceUnavailableCount: UInt64 = 0

    package static func makeProductShell()
        -> HostAgentXPCListenerAdmissionShell
    {
        let listener = HostAgentXPCListenerFactory.makeListener()
        return HostAgentXPCListenerAdmissionShell(
            listener: listener,
            assessConnection: HostAgentXPCPeerAdmissionGate.assess
        )
    }

    init(
        listener: NSXPCListener,
        assessConnection: @escaping ConnectionAssessor
    ) {
        self.listener = listener
        self.assessConnection = assessConnection
        super.init()
        listener.delegate = self
    }

    package func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard listener === self.listener else {
            recordRejectedPeerIdentity()
            return false
        }
        let admission = assessConnection(newConnection)

        lock.lock()
        incrementSaturating(&connectionAttemptCount)
        if admission == .eligible {
            incrementSaturating(&rejectedInterfaceUnavailableCount)
        } else {
            incrementSaturating(&rejectedPeerIdentityCount)
        }
        lock.unlock()

        return false
    }

    private func recordRejectedPeerIdentity() {
        lock.lock()
        incrementSaturating(&connectionAttemptCount)
        incrementSaturating(&rejectedPeerIdentityCount)
        lock.unlock()
    }

    package func snapshot() -> HostAgentXPCListenerAdmissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostAgentXPCListenerAdmissionSnapshot(
            connectionAttemptCount: connectionAttemptCount,
            rejectedPeerIdentityCount: rejectedPeerIdentityCount,
            rejectedInterfaceUnavailableCount:
                rejectedInterfaceUnavailableCount
        )
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}
