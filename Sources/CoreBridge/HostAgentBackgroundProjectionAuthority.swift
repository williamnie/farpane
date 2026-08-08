import Foundation

package enum HostAgentBackgroundProjectionFailure: Equatable, Sendable {
    case invalidProjection
    case generationExhausted
}

package struct HostAgentBackgroundProjection: Equatable, Sendable {
    package let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    package let payload: HostAgentXPCWireSnapshotPayload
    package let snapshotEventID: UInt64

    fileprivate init(
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        response: HostAgentXPCWireSnapshotResponse
    ) {
        self.peerIdentity = peerIdentity
        payload = response.snapshot
        snapshotEventID = response.lastEventID
    }
}

package enum HostAgentBackgroundProjectionPhase: Equatable, Sendable {
    case idle
    case waitingForSnapshot
    case replacingIdentity
    case available(HostAgentBackgroundProjection)
    case terminated(HostAgentXPCSessionTerminationReason)
    case failed(HostAgentBackgroundProjectionFailure)
}

package struct HostAgentBackgroundProjectionView: Equatable, Sendable {
    package let generation: UInt64
    package let phase: HostAgentBackgroundProjectionPhase

    fileprivate init(
        generation: UInt64,
        phase: HostAgentBackgroundProjectionPhase
    ) {
        self.generation = generation
        self.phase = phase
    }

    package var handshakeStatus: HostAgentBackgroundHandshakeStatus {
        switch phase {
        case .replacingIdentity, .available:
            return .compatible
        case .terminated(.incompatible):
            return .incompatible
        case .idle, .waitingForSnapshot, .terminated, .failed:
            return .disconnected
        }
    }

    package var snapshotStatus: HostAgentBackgroundSnapshotStatus {
        if case .available = phase { return .available }
        return .unavailable
    }

    package var rendezvousStatus: HostAgentBackgroundRendezvousStatus {
        switch phase {
        case .available(let projection):
            switch projection.payload.registrationStatus {
            case "ready":
                return .registered
            case "notStarted", "pending":
                return .checking
            case "degraded":
                return .offline
            default:
                return .offline
            }
        case .idle, .waitingForSnapshot, .replacingIdentity:
            return .checking
        case .terminated, .failed:
            return .offline
        }
    }
}

package struct HostAgentBackgroundProjectionSessionBinding: Sendable {
    package let previousPeerIdentity:
        HostAgentXPCSnapshotClientPeerIdentity?
    package let sink: HostAgentXPCSessionProjectionSink

    fileprivate init(
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        sink: HostAgentXPCSessionProjectionSink
    ) {
        self.previousPeerIdentity = previousPeerIdentity
        self.sink = sink
    }
}

/// App-owned, process-local projection authority. Each session receives an
/// epoch-bound sink, so callbacks from a replaced lifecycle cannot alter the
/// current component state. Only validated typed payloads are retained.
package final class HostAgentBackgroundProjectionAuthority:
    @unchecked Sendable
{
    package typealias Observer = @Sendable
        (HostAgentBackgroundProjectionView) -> Void

    private struct ActiveSession {
        let epoch: UInt64
        let previousPeerIdentity:
            HostAgentXPCSnapshotClientPeerIdentity?
        var replacementResetObserved = false
        var peerIdentity: HostAgentXPCSnapshotClientPeerIdentity?
        var eventCursor: UInt64?
    }

    private let lock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let observer: Observer
    private var view = HostAgentBackgroundProjectionView(
        generation: 0,
        phase: .idle
    )
    private var nextSessionEpoch: UInt64 = 0
    private var activeSession: ActiveSession?
    private var lastPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?

    package init(observer: @escaping Observer = { _ in }) {
        self.observer = observer
    }

    package func snapshot() -> HostAgentBackgroundProjectionView {
        lock.lock()
        defer { lock.unlock() }
        return view
    }

    package func beginSession()
        -> HostAgentBackgroundProjectionSessionBinding
    {
        deliveryLock.lock()
        lock.lock()
        let previousPeerIdentity = lastPeerIdentity
        let epoch: UInt64
        let publication: HostAgentBackgroundProjectionView
        if nextSessionEpoch == UInt64.max {
            activeSession = nil
            publication = replacePhase(.failed(.generationExhausted))
            epoch = UInt64.max
        } else {
            nextSessionEpoch += 1
            epoch = nextSessionEpoch
            activeSession = ActiveSession(
                epoch: epoch,
                previousPeerIdentity: previousPeerIdentity
            )
            publication = replacePhase(.waitingForSnapshot)
        }
        lock.unlock()
        observer(publication)
        deliveryLock.unlock()

        return HostAgentBackgroundProjectionSessionBinding(
            previousPeerIdentity: previousPeerIdentity,
            sink: HostAgentBackgroundProjectionSessionSink(
                authority: self,
                sessionEpoch: epoch
            )
        )
    }

    fileprivate func resetForIdentityReplacement(sessionEpoch: UInt64) {
        serializeMutation {
            guard var session = currentSession(sessionEpoch),
                  session.previousPeerIdentity != nil,
                  session.peerIdentity == nil,
                  !session.replacementResetObserved,
                  view.phase == .waitingForSnapshot
            else {
                return failCurrentSessionIfCurrent(sessionEpoch)
            }
            session.replacementResetObserved = true
            activeSession = session
            return replacePhase(.replacingIdentity)
        }
    }

    fileprivate func publishInitialSnapshot(
        _ response: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition,
        sessionEpoch: UInt64
    ) {
        serializeMutation {
            guard var session = currentSession(sessionEpoch),
                  session.peerIdentity == nil,
                  validResponseIdentity(response, peerIdentity: peerIdentity),
                  validInitialTransition(
                    transition,
                    peerIdentity: peerIdentity,
                    session: session
                  )
            else {
                return failCurrentSessionIfCurrent(sessionEpoch)
            }
            session.peerIdentity = peerIdentity
            session.eventCursor = response.lastEventID
            activeSession = session
            lastPeerIdentity = peerIdentity
            return replacePhase(.available(
                HostAgentBackgroundProjection(
                    peerIdentity: peerIdentity,
                    response: response
                )
            ))
        }
    }

    fileprivate func publishEvents(
        _ response: HostAgentXPCWireEventCursorResponse,
        sessionEpoch: UInt64
    ) {
        serializeMutation {
            guard var session = currentSession(sessionEpoch),
                  let peerIdentity = session.peerIdentity,
                  let eventCursor = session.eventCursor,
                  case .available = view.phase,
                  validEventIdentity(
                    response,
                    peerIdentity: peerIdentity
                  ),
                  let nextCursor = validNextCursor(
                    response,
                    after: eventCursor
                  )
            else {
                return failCurrentSessionIfCurrent(sessionEpoch)
            }
            session.eventCursor = nextCursor
            activeSession = session
            return nil
        }
    }

    fileprivate func publishResynchronizedSnapshot(
        _ response: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse,
        sessionEpoch: UInt64
    ) {
        serializeMutation {
            guard var session = currentSession(sessionEpoch),
                  let peerIdentity = session.peerIdentity,
                  let currentProjection = availableProjection,
                  validResponseIdentity(response, peerIdentity: peerIdentity),
                  validEventIdentity(
                    triggeringResponse,
                    peerIdentity: peerIdentity
                  ),
                  requiresResynchronization(triggeringResponse),
                  response.lastEventID >= triggeringResponse.latestEventID,
                  response.snapshot.observedAt
                    >= currentProjection.payload.observedAt
            else {
                return failCurrentSessionIfCurrent(sessionEpoch)
            }
            session.eventCursor = response.lastEventID
            activeSession = session
            return replacePhase(.available(
                HostAgentBackgroundProjection(
                    peerIdentity: peerIdentity,
                    response: response
                )
            ))
        }
    }

    fileprivate func sessionDidTerminate(
        _ reason: HostAgentXPCSessionTerminationReason,
        sessionEpoch: UInt64
    ) {
        serializeMutation {
            guard currentSession(sessionEpoch) != nil else { return nil }
            activeSession = nil
            return replacePhase(.terminated(reason))
        }
    }

    private var availableProjection: HostAgentBackgroundProjection? {
        if case .available(let projection) = view.phase { return projection }
        return nil
    }

    private func currentSession(_ epoch: UInt64) -> ActiveSession? {
        guard let session = activeSession, session.epoch == epoch else {
            return nil
        }
        return session
    }

    private func validInitialTransition(
        _ transition: HostAgentXPCSnapshotClientIdentityTransition,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        session: ActiveSession
    ) -> Bool {
        switch session.previousPeerIdentity {
        case nil:
            return transition == .firstObservation
                && !session.replacementResetObserved
                && view.phase == .waitingForSnapshot
        case .some(let previousPeerIdentity)
            where previousPeerIdentity == peerIdentity:
            return transition == .unchanged
                && !session.replacementResetObserved
                && view.phase == .waitingForSnapshot
        case .some:
            return transition == .replacedPrevious
                && session.replacementResetObserved
                && view.phase == .replacingIdentity
        }
    }

    private func validResponseIdentity(
        _ response: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        response.hostInstanceID == peerIdentity.hostInstanceID
            && response.agentBootID == peerIdentity.agentBootID
    }

    private func validEventIdentity(
        _ response: HostAgentXPCWireEventCursorResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        response.hostInstanceID == peerIdentity.hostInstanceID
            && response.agentBootID == peerIdentity.agentBootID
    }

    private func validNextCursor(
        _ response: HostAgentXPCWireEventCursorResponse,
        after currentCursor: UInt64
    ) -> UInt64? {
        guard response.events.allSatisfy({ event in
            if case .commandResult = event.payload { return true }
            return false
        }) else { return nil }
        switch response.outcome {
        case .upToDate:
            guard response.latestEventID == currentCursor,
                  response.resumeAfterEventID == nil,
                  response.events.isEmpty
            else { return nil }
            return currentCursor
        case .batch:
            guard let nextCursor = response.resumeAfterEventID,
                  nextCursor > currentCursor,
                  response.latestEventID >= nextCursor
            else { return nil }
            var previousEventID = currentCursor
            for event in response.events {
                guard event.eventID > previousEventID,
                      event.eventID <= nextCursor
                else { return nil }
                previousEventID = event.eventID
            }
            return nextCursor
        case .gap, .invalidCursor, .resnapshotRequired:
            return nil
        }
    }

    private func requiresResynchronization(
        _ response: HostAgentXPCWireEventCursorResponse
    ) -> Bool {
        switch response.outcome {
        case .gap, .invalidCursor, .resnapshotRequired:
            return true
        case .batch:
            return response.events.contains { event in
                if case .snapshotChanged = event.payload { return true }
                return false
            }
        case .upToDate:
            return false
        }
    }

    private func failCurrentSessionIfCurrent(
        _ sessionEpoch: UInt64
    ) -> HostAgentBackgroundProjectionView? {
        guard currentSession(sessionEpoch) != nil else { return nil }
        activeSession = nil
        return replacePhase(.failed(.invalidProjection))
    }

    private func replacePhase(
        _ phase: HostAgentBackgroundProjectionPhase
    ) -> HostAgentBackgroundProjectionView {
        guard view.generation < UInt64.max else {
            view = HostAgentBackgroundProjectionView(
                generation: UInt64.max,
                phase: .failed(.generationExhausted)
            )
            activeSession = nil
            return view
        }
        view = HostAgentBackgroundProjectionView(
            generation: view.generation + 1,
            phase: phase
        )
        return view
    }

    private func serializeMutation(
        _ mutation: () -> HostAgentBackgroundProjectionView?
    ) {
        deliveryLock.lock()
        lock.lock()
        let publication = mutation()
        lock.unlock()
        if let publication { observer(publication) }
        deliveryLock.unlock()
    }
}

private final class HostAgentBackgroundProjectionSessionSink:
    HostAgentXPCSessionProjectionSink,
    @unchecked Sendable
{
    private let authority: HostAgentBackgroundProjectionAuthority
    private let sessionEpoch: UInt64

    init(
        authority: HostAgentBackgroundProjectionAuthority,
        sessionEpoch: UInt64
    ) {
        self.authority = authority
        self.sessionEpoch = sessionEpoch
    }

    func resetForIdentityReplacement() {
        authority.resetForIdentityReplacement(sessionEpoch: sessionEpoch)
    }

    func publishInitialSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) {
        authority.publishInitialSnapshot(
            snapshot,
            peerIdentity: peerIdentity,
            transition: transition,
            sessionEpoch: sessionEpoch
        )
    }

    func publishEvents(_ response: HostAgentXPCWireEventCursorResponse) {
        authority.publishEvents(response, sessionEpoch: sessionEpoch)
    }

    func publishResynchronizedSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    ) {
        authority.publishResynchronizedSnapshot(
            snapshot,
            triggeringResponse: triggeringResponse,
            sessionEpoch: sessionEpoch
        )
    }

    func sessionDidTerminate(_ reason: HostAgentXPCSessionTerminationReason) {
        authority.sessionDidTerminate(reason, sessionEpoch: sessionEpoch)
    }
}
