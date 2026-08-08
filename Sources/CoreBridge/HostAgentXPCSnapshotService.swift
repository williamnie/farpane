import CoreBridgeShim
import Foundation

package enum HostAgentXPCSnapshotSessionState: Equatable, Sendable {
    case awaitingHandshake
    case negotiating
    case compatible(wireVersion: UInt64)
    case fetchingSnapshot(
        wireVersion: UInt64,
        previousAfterEventID: UInt64?
    )
    case snapshotReady(wireVersion: UInt64, afterEventID: UInt64)
    case fetchingEvents(wireVersion: UInt64, afterEventID: UInt64)
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

    package static var eventSelectorName: String {
        NSStringFromSelector(
            #selector(
                RDNHostAgentXPCEventService.fetchEvents(
                    requestData:reply:
                )
            )
        )
    }

    package static func makeInterface() -> NSXPCInterface {
        NSXPCInterface(with: RDNHostAgentXPCEventService.self)
    }
}

/// Per-connection snapshot-first state machine. Event cursor requests stay
/// bound to the exact successful snapshot cursor on this same connection.
/// The command surface is not present.
package final class HostAgentXPCSnapshotSessionHandler:
    NSObject,
    RDNHostAgentXPCEventService,
    @unchecked Sendable
{
    package typealias MonotonicClock = @Sendable () -> UInt64
    package static let minimumSnapshotIntervalMilliseconds: UInt64 = 100
    package static let minimumEventIntervalMilliseconds: UInt64 = 100

    private let lock = NSLock()
    private let identity: HostAgentXPCWireAgentIdentity
    private let snapshotState: HostAgentSnapshotState
    private let eventState: HostAgentEventState
    private let nowUnixMilliseconds: HostAgentXPCHandshakeHandler.Clock
    private let monotonicMilliseconds: MonotonicClock
    private var state: HostAgentXPCSnapshotSessionState = .awaitingHandshake
    private var lastSnapshotAttemptAt: UInt64?
    private var lastEventAttemptAt: UInt64?

    package init(
        identity: HostAgentXPCWireAgentIdentity,
        snapshotState: HostAgentSnapshotState,
        eventState: HostAgentEventState,
        nowUnixMilliseconds: @escaping HostAgentXPCHandshakeHandler.Clock,
        monotonicMilliseconds: @escaping MonotonicClock
    ) {
        self.identity = identity
        self.snapshotState = snapshotState
        self.eventState = eventState
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
        let request: HostAgentXPCWireSnapshotRequest
        do {
            request = try HostAgentXPCWireSnapshotRequest.decode(requestData)
        } catch {
            return nil
        }
        guard canAttemptSnapshot(request: request) else { return nil }
        let monotonic = monotonicMilliseconds()
        guard let reservation = reserveSnapshotAttempt(
                request: request,
                monotonicMilliseconds: monotonic
              )
        else { return nil }
        do {
            let response = try HostAgentXPCWireSnapshotResponse.make(
                for: request,
                identity: identity,
                state: snapshotState.snapshot(),
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
            let data = try response.encoded()
            finishSnapshot(
                reservation,
                afterEventID: response.lastEventID
            )
            return data
        } catch {
            restoreSnapshot(reservation)
            return nil
        }
    }

    package func eventResponse(for requestData: Data) -> Data? {
        let request: HostAgentXPCWireEventCursorRequest
        do {
            request = try HostAgentXPCWireEventCursorRequest.decode(requestData)
        } catch {
            return nil
        }
        guard canAttemptEvents(request: request) else { return nil }
        let monotonic = monotonicMilliseconds()
        guard reserveEventAttempt(
                request: request,
                monotonicMilliseconds: monotonic
              )
        else { return nil }
        do {
            let replay = try eventState.replay(
                afterSequence: request.afterEventID,
                limit: request.maximumEventCount
            )
            let response = try HostAgentXPCWireEventCursorResponse.make(
                for: request,
                identity: identity,
                replay: replay,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
            let data = try response.encoded()
            finishEvents(request: request, response: response)
            return data
        } catch {
            restoreEvents(request: request)
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

    package func fetchEvents(
        requestData: Data,
        reply: @escaping (Data?) -> Void
    ) {
        reply(eventResponse(for: requestData))
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

    private struct SnapshotReservation: Equatable, Sendable {
        let wireVersion: UInt64
        let previousAfterEventID: UInt64?
    }

    private func canAttemptSnapshot(
        request: HostAgentXPCWireSnapshotRequest
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID
        else { return false }
        switch state {
        case .compatible(let wireVersion),
             .snapshotReady(let wireVersion, _):
            return request.wireVersion == wireVersion
        default:
            return false
        }
    }

    private func reserveSnapshotAttempt(
        request: HostAgentXPCWireSnapshotRequest,
        monotonicMilliseconds: UInt64
    ) -> SnapshotReservation? {
        lock.lock()
        defer { lock.unlock() }
        let reservation: SnapshotReservation
        switch state {
        case .compatible(let wireVersion):
            reservation = SnapshotReservation(
                wireVersion: wireVersion,
                previousAfterEventID: nil
            )
        case .snapshotReady(let wireVersion, let afterEventID):
            reservation = SnapshotReservation(
                wireVersion: wireVersion,
                previousAfterEventID: afterEventID
            )
        default:
            return nil
        }
        guard request.wireVersion == reservation.wireVersion,
              request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID,
              monotonicMilliseconds > 0
        else { return nil }
        if let lastSnapshotAttemptAt {
            guard monotonicMilliseconds >= lastSnapshotAttemptAt,
                  monotonicMilliseconds - lastSnapshotAttemptAt
                    >= Self.minimumSnapshotIntervalMilliseconds
            else { return nil }
        }
        lastSnapshotAttemptAt = monotonicMilliseconds
        state = .fetchingSnapshot(
            wireVersion: reservation.wireVersion,
            previousAfterEventID: reservation.previousAfterEventID
        )
        return reservation
    }

    private func finishSnapshot(
        _ reservation: SnapshotReservation,
        afterEventID: UInt64
    ) {
        lock.lock()
        if state == .fetchingSnapshot(
            wireVersion: reservation.wireVersion,
            previousAfterEventID: reservation.previousAfterEventID
        ) {
            state = .snapshotReady(
                wireVersion: reservation.wireVersion,
                afterEventID: afterEventID
            )
        }
        lock.unlock()
    }

    private func restoreSnapshot(_ reservation: SnapshotReservation) {
        lock.lock()
        if state == .fetchingSnapshot(
            wireVersion: reservation.wireVersion,
            previousAfterEventID: reservation.previousAfterEventID
        ) {
            if let previousAfterEventID = reservation.previousAfterEventID {
                state = .snapshotReady(
                    wireVersion: reservation.wireVersion,
                    afterEventID: previousAfterEventID
                )
            } else {
                state = .compatible(wireVersion: reservation.wireVersion)
            }
        }
        lock.unlock()
    }

    private func canAttemptEvents(
        request: HostAgentXPCWireEventCursorRequest
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .snapshotReady(let wireVersion, let afterEventID) = state
        else { return false }
        return request.wireVersion == wireVersion
            && request.hostInstanceID == identity.hostInstanceID
            && request.agentBootID == identity.agentBootID
            && request.afterEventID == afterEventID
    }

    private func reserveEventAttempt(
        request: HostAgentXPCWireEventCursorRequest,
        monotonicMilliseconds: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .snapshotReady(
                wireVersion: request.wireVersion,
                afterEventID: request.afterEventID
              ),
              request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID,
              monotonicMilliseconds > 0
        else { return false }
        if let lastEventAttemptAt {
            guard monotonicMilliseconds >= lastEventAttemptAt,
                  monotonicMilliseconds - lastEventAttemptAt
                    >= Self.minimumEventIntervalMilliseconds
            else { return false }
        }
        lastEventAttemptAt = monotonicMilliseconds
        state = .fetchingEvents(
            wireVersion: request.wireVersion,
            afterEventID: request.afterEventID
        )
        return true
    }

    private func finishEvents(
        request: HostAgentXPCWireEventCursorRequest,
        response: HostAgentXPCWireEventCursorResponse
    ) {
        lock.lock()
        guard state == .fetchingEvents(
                wireVersion: request.wireVersion,
                afterEventID: request.afterEventID
              )
        else {
            lock.unlock()
            return
        }
        switch response.outcome {
        case .batch:
            if let resumeAfterEventID = response.resumeAfterEventID {
                state = .snapshotReady(
                    wireVersion: request.wireVersion,
                    afterEventID: resumeAfterEventID
                )
            } else {
                state = .compatible(wireVersion: request.wireVersion)
            }
        case .upToDate:
            state = .snapshotReady(
                wireVersion: request.wireVersion,
                afterEventID: request.afterEventID
            )
        case .gap, .invalidCursor, .resnapshotRequired:
            state = .compatible(wireVersion: request.wireVersion)
        }
        lock.unlock()
    }

    private func restoreEvents(
        request: HostAgentXPCWireEventCursorRequest
    ) {
        lock.lock()
        if state == .fetchingEvents(
            wireVersion: request.wireVersion,
            afterEventID: request.afterEventID
        ) {
            state = .snapshotReady(
                wireVersion: request.wireVersion,
                afterEventID: request.afterEventID
            )
        }
        lock.unlock()
    }
}
