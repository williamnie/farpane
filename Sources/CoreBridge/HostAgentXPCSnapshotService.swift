import CoreBridgeShim
import Foundation

package enum HostAgentXPCSnapshotSessionState: Equatable, Sendable {
    case awaitingHandshake
    case negotiating
    case compatible(wireVersion: UInt64)
    case incompatible
}

package enum HostAgentXPCSnapshotInterfaceFactory {
    package static var handshakeSelectorName: String {
        NSStringFromSelector(
            #selector(
                RDNHostAgentXPCSnapshotService.performHandshake(
                    requestData:reply:
                )
            )
        )
    }

    package static var snapshotSelectorName: String {
        NSStringFromSelector(
            #selector(
                RDNHostAgentXPCSnapshotService.fetchSnapshot(
                    requestData:reply:
                )
            )
        )
    }

    package static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: RDNHostAgentXPCSnapshotService.self)
    }
}

/// Per-connection state machine for the snapshot-first XPC surface. A valid
/// handshake is one-shot; snapshot requests stay bound to its exact identity
/// and negotiated wire version. Event and command surfaces are not present.
package final class HostAgentXPCSnapshotSessionHandler:
    NSObject,
    RDNHostAgentXPCSnapshotService,
    @unchecked Sendable
{
    package typealias MonotonicClock = @Sendable () -> UInt64
    package static let minimumSnapshotIntervalMilliseconds: UInt64 = 100

    private let lock = NSLock()
    private let identity: HostAgentXPCWireAgentIdentity
    private let snapshotState: HostAgentSnapshotState
    private let nowUnixMilliseconds: HostAgentXPCHandshakeHandler.Clock
    private let monotonicMilliseconds: MonotonicClock
    private var state: HostAgentXPCSnapshotSessionState = .awaitingHandshake
    private var lastSnapshotAttemptAt: UInt64?

    package init(
        identity: HostAgentXPCWireAgentIdentity,
        snapshotState: HostAgentSnapshotState,
        nowUnixMilliseconds: @escaping HostAgentXPCHandshakeHandler.Clock,
        monotonicMilliseconds: @escaping MonotonicClock
    ) {
        self.identity = identity
        self.snapshotState = snapshotState
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.monotonicMilliseconds = monotonicMilliseconds
    }

    package func stateSnapshot() -> HostAgentXPCSnapshotSessionState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    package func handshakeResponse(for requestData: Data) -> Data? {
        lock.lock()
        guard state == .awaitingHandshake else {
            lock.unlock()
            return nil
        }
        state = .negotiating
        lock.unlock()

        do {
            let request = try HostAgentXPCWireHandshakeRequest.decode(requestData)
            let response = try HostAgentXPCWireHandshakeNegotiator.makeResponse(
                for: request,
                agentBuildID: identity.agentBuildID,
                hostInstanceID: identity.hostInstanceID,
                agentBootID: identity.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
            let data = try response.encoded()
            let terminalState: HostAgentXPCSnapshotSessionState
            switch HostAgentXPCWireHandshakeNegotiator.evaluate(
                response,
                for: request
            ) {
            case .compatible(let selectedWireVersion):
                terminalState = .compatible(
                    wireVersion: selectedWireVersion
                )
            case .incompatible:
                terminalState = .incompatible
            case .invalidResponse:
                throw HostAgentXPCWireHandshakeDocumentError.invalidDocument
            }
            finishNegotiation(with: terminalState)
            return data
        } catch {
            finishNegotiation(with: .awaitingHandshake)
            return nil
        }
    }

    package func snapshotResponse(for requestData: Data) -> Data? {
        do {
            let request = try HostAgentXPCWireSnapshotRequest.decode(requestData)
            let sentAt = nowUnixMilliseconds()
            guard reserveSnapshotAttempt(
                request: request,
                monotonicMilliseconds: monotonicMilliseconds()
            ) else { return nil }
            let response = try HostAgentXPCWireSnapshotResponse.make(
                for: request,
                identity: identity,
                state: snapshotState.snapshot(),
                sentAtUnixMilliseconds: sentAt
            )
            return try response.encoded()
        } catch {
            return nil
        }
    }

    package func performHandshake(
        requestData: Data,
        reply: @escaping (Data?) -> Void
    ) {
        reply(handshakeResponse(for: requestData))
    }

    package func fetchSnapshot(
        requestData: Data,
        reply: @escaping (Data?) -> Void
    ) {
        reply(snapshotResponse(for: requestData))
    }

    private func finishNegotiation(
        with result: HostAgentXPCSnapshotSessionState
    ) {
        lock.lock()
        if state == .negotiating {
            state = result
        }
        lock.unlock()
    }

    private func reserveSnapshotAttempt(
        request: HostAgentXPCWireSnapshotRequest,
        monotonicMilliseconds: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .compatible(wireVersion: request.wireVersion),
              request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID,
              monotonicMilliseconds > 0
        else { return false }
        if let lastSnapshotAttemptAt {
            guard monotonicMilliseconds >= lastSnapshotAttemptAt,
                  monotonicMilliseconds - lastSnapshotAttemptAt
                    >= Self.minimumSnapshotIntervalMilliseconds
            else { return false }
        }
        lastSnapshotAttemptAt = monotonicMilliseconds
        return true
    }
}
