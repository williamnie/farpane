import CoreBridgeShim
import Foundation

extension HostAgentXPCSnapshotClient {
    func receiveEvents(
        _ data: Data?, request: HostAgentXPCWireEventCursorRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) {
        guard
            isAwaitingEvents(
                requestID: request.requestID, peerIdentity: peerIdentity,
                afterEventID: request.afterEventID), let data,
            let response = try? HostAgentXPCWireEventCursorResponse.decode(data),
            response.evaluate(for: request) == .correlated
        else {
            if isAwaitingEvents(
                requestID: request.requestID, peerIdentity: peerIdentity,
                afterEventID: request.afterEventID)
            {
                finishEventPending(
                    state: .failed, result: .invalidResponse, invalidateTransport: true)
            }
            return
        }

        let commandInspection = inspectCommandResult(in: response)
        if case .conflicting = commandInspection {
            finishEventPending(
                state: .failed, result: .invalidResponse, invalidateTransport: true,
                commandTerminalResult: .invalidResponse)
            return
        }

        if responseRequiresSnapshot(response) {
            beginEventResnapshot(
                response: response, request: request, peerIdentity: peerIdentity,
                commandResult: commandInspection.matchingResult)
            return
        }

        let nextEventID: UInt64
        switch response.outcome {
        case .upToDate: nextEventID = request.afterEventID
        case .batch:
            guard let resumeAfterEventID = response.resumeAfterEventID else {
                finishEventPending(
                    state: .failed, result: .invalidResponse, invalidateTransport: true)
                return
            }
            nextEventID = resumeAfterEventID
        case .gap, .invalidCursor, .resnapshotRequired:
            finishEventPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
            return
        }

        lock.lock()
        guard state == .fetchingEvents(peerIdentity, afterEventID: request.afterEventID),
            eventRequest?.requestID == request.requestID
        else {
            lock.unlock()
            return
        }
        state = .ready(peerIdentity, lastEventID: nextEventID)
        eventRequest = nil
        let eventCompletion = self.eventCompletion
        self.eventCompletion = nil
        let commandDelivery = claimCommandResultLocked(commandInspection.matchingResult)
        lock.unlock()
        eventCompletion?(.events(response))
        if let commandDelivery { commandDelivery.observer(.completed(commandDelivery.result)) }
    }

    func responseRequiresSnapshot(_ response: HostAgentXPCWireEventCursorResponse) -> Bool {
        switch response.outcome {
        case .gap, .invalidCursor, .resnapshotRequired: return true
        case .upToDate: return false
        case .batch:
            return response.events.contains { event in
                if case .snapshotChanged = event.payload { return true }
                return false
            }
        }
    }

    func inspectCommandResult(in response: HostAgentXPCWireEventCursorResponse)
        -> CommandResultInspection
    {
        lock.lock()
        guard case .awaitingResult(let request) = pendingCommand else {
            lock.unlock()
            return .none
        }
        let commandID = request.commandID
        lock.unlock()

        var matched: HostAgentXPCWireCommandResult?
        for event in response.events {
            guard case .commandResult(let result) = event.payload, result.commandID == commandID
            else { continue }
            if let matched, matched != result { return .conflicting }
            matched = result
        }
        guard let matched else { return .none }
        return .matching(matched)
    }

    /// Caller holds `lock`.

    func claimCommandResultLocked(_ result: HostAgentXPCWireCommandResult?) -> CommandDelivery? {
        guard let result, case .awaitingResult(let request) = pendingCommand,
            request.commandID == result.commandID, let commandObserver
        else { return nil }
        pendingCommand = nil
        self.commandObserver = nil
        refreshCommandResult = nil
        return CommandDelivery(observer: commandObserver, result: result)
    }

    func beginEventResnapshot(
        response: HostAgentXPCWireEventCursorResponse, request: HostAgentXPCWireEventCursorRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        commandResult: HostAgentXPCWireCommandResult?
    ) {
        let snapshotRequest: HostAgentXPCWireSnapshotRequest
        do {
            snapshotRequest = try HostAgentXPCWireSnapshotRequest(
                requestID: makeRequestID(), wireVersion: request.wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID, agentBootID: peerIdentity.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds())
        } catch {
            finishEventPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
            return
        }

        lock.lock()
        guard state == .fetchingEvents(peerIdentity, afterEventID: request.afterEventID),
            eventRequest?.requestID == request.requestID
        else {
            lock.unlock()
            return
        }
        state = .refreshingSnapshot(peerIdentity, lastEventID: request.afterEventID)
        eventRequest = nil
        self.snapshotRequest = snapshotRequest
        refreshTrigger = response
        refreshCommandResult = commandResult
        lock.unlock()

        do {
            transport.fetchSnapshot(requestData: try snapshotRequest.encoded()) {
                [weak self] data in
                self?.receiveSnapshot(data, request: snapshotRequest, peerIdentity: peerIdentity)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: snapshotRequest.requestID)
            }
        } catch {
            finishEventPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
        }
    }

    @discardableResult func finishRefreshedSnapshot(
        _ response: HostAgentXPCWireSnapshotResponse, request: HostAgentXPCWireSnapshotRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        lock.lock()
        guard case .refreshingSnapshot(let expectedPeer, _) = state, expectedPeer == peerIdentity,
            snapshotRequest?.requestID == request.requestID, let refreshTrigger, let eventCompletion
        else {
            lock.unlock()
            return false
        }
        state = .ready(peerIdentity, lastEventID: response.lastEventID)
        snapshotRequest = nil
        self.refreshTrigger = nil
        self.eventCompletion = nil
        let commandDelivery = claimCommandResultLocked(refreshCommandResult)
        let unknownCommandObserver: CommandObserver?
        if commandDelivery == nil, case .awaitingResult = pendingCommand {
            unknownCommandObserver = commandObserver
            pendingCommand = nil
            commandObserver = nil
        } else {
            unknownCommandObserver = nil
        }
        refreshCommandResult = nil
        lock.unlock()
        eventCompletion(.resynchronized(snapshot: response, triggeringResponse: refreshTrigger))
        if let commandDelivery {
            commandDelivery.observer(.completed(commandDelivery.result))
        } else {
            unknownCommandObserver?(.resultUnknown)
        }
        return true
    }
}
