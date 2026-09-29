import CoreBridgeShim
import Foundation

extension HostAgentXPCSnapshotClient {
    func identityTransition(to peerIdentity: HostAgentXPCSnapshotClientPeerIdentity)
        -> HostAgentXPCSnapshotClientIdentityTransition
    {
        guard let previousPeerIdentity else { return .firstObservation }
        guard previousPeerIdentity == peerIdentity else { return .replacedPrevious }
        return .unchanged
    }

    func requestDidTimeOut(requestID: String) {
        lock.lock()
        let isInitialRequest =
            completion != nil
            && (handshakeRequest?.requestID == requestID || snapshotRequest?.requestID == requestID)
        let isEventRequest =
            eventCompletion != nil
            && (eventRequest?.requestID == requestID || snapshotRequest?.requestID == requestID)
        let isPasswordRequest = passwordRequest?.requestID == requestID
        lock.unlock()
        if isPasswordRequest {
            finishPasswordOperation(result: .timedOut, invalidateTransport: true)
        } else if isEventRequest {
            finishEventPending(state: .failed, result: .timedOut, invalidateTransport: true)
        } else if isInitialRequest {
            finishPending(state: .failed, result: .timedOut, invalidateTransport: true)
        }
    }

    func commandAcceptanceDidTimeOut(requestID: String) {
        guard isAwaitingCommandAcceptance(requestID: requestID) else { return }
        finishCommandAcceptance(result: .acceptanceTimedOut, invalidateTransport: true)
    }

    func commandResultDidTimeOut(requestID: String) {
        lock.lock()
        guard case .awaitingResult(let request) = pendingCommand, request.requestID == requestID,
            let commandObserver
        else {
            lock.unlock()
            return
        }
        pendingCommand = nil
        self.commandObserver = nil
        refreshCommandResult = nil
        lock.unlock()
        commandObserver(.resultTimedOut)
    }

    func transportDidEnd() {
        var initialCompletion: Completion?
        var eventCompletion: EventCompletion?
        var commandObserver: CommandObserver?
        var commandResult: HostAgentXPCSnapshotClientCommandResult?
        var passwordCompletion: PasswordCompletion?
        var notifyConnectionEnded = false
        lock.lock()
        switch state {
        case .handshaking, .fetchingSnapshot, .deliveringSnapshot:
            state = .disconnected
            initialCompletion = completion
            self.completion = nil
        case .fetchingEvents, .refreshingSnapshot:
            state = .disconnected
            eventCompletion = self.eventCompletion
            self.eventCompletion = nil
            notifyConnectionEnded = true
        case .submittingCommand:
            state = .disconnected
            notifyConnectionEnded = true
        case .performingPasswordOperation:
            state = .disconnected
            passwordCompletion = self.passwordCompletion
            self.passwordCompletion = nil
            notifyConnectionEnded = true
        case .ready:
            state = .disconnected
            notifyConnectionEnded = true
        default:
            lock.unlock()
            return
        }
        if let observer = self.commandObserver {
            commandObserver = observer
            switch pendingCommand {
            case .submitting: commandResult = .disconnected
            case .awaitingResult: commandResult = .resultUnknown
            case .none: commandResult = nil
            }
        }
        handshakeRequest = nil
        snapshotRequest = nil
        eventRequest = nil
        refreshTrigger = nil
        refreshCommandResult = nil
        pendingCommand = nil
        passwordRequest = nil
        self.commandObserver = nil
        negotiatedWireVersion = nil
        lock.unlock()

        initialCompletion?(.disconnected)
        eventCompletion?(.disconnected)
        if let commandResult { commandObserver?(commandResult) }
        passwordCompletion?(.disconnected)
        if notifyConnectionEnded { onConnectionEnded() }
    }

    func isAwaitingHandshake(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .handshaking && handshakeRequest?.requestID == requestID
    }

    func isAwaitingSnapshot(requestID: String, peerIdentity: HostAgentXPCSnapshotClientPeerIdentity)
        -> Bool
    {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .fetchingSnapshot(let expectedPeer):
            return expectedPeer == peerIdentity && snapshotRequest?.requestID == requestID
        case .refreshingSnapshot(let expectedPeer, _):
            return expectedPeer == peerIdentity && snapshotRequest?.requestID == requestID
        default: return false
        }
    }

    func isRefreshingSnapshot(
        requestID: String, peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .refreshingSnapshot(let expectedPeer, _) = state else { return false }
        return expectedPeer == peerIdentity && snapshotRequest?.requestID == requestID
    }

    func isAwaitingEvents(
        requestID: String, peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        afterEventID: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .fetchingEvents(peerIdentity, afterEventID: afterEventID)
            && eventRequest?.requestID == requestID
    }

    func isAwaitingCommandAcceptance(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .submitting(let request, let peerIdentity, let cursor) = pendingCommand else {
            return false
        }
        return request.requestID == requestID
            && state
                == .submittingCommand(
                    peerIdentity, lastEventID: cursor, commandID: request.commandID)
    }

    func isAwaitingPasswordOperation(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .performingPasswordOperation(_, _, let expectedID) = state else { return false }
        return expectedID == requestID && passwordRequest?.requestID == requestID
    }

    func passwordOperationDidTimeOut(requestID: String) {
        guard isAwaitingPasswordOperation(requestID: requestID) else { return }
        finishPasswordOperation(result: .timedOut, invalidateTransport: true)
    }

    func finishPasswordOperation(
        result: HostAgentXPCSnapshotClientPasswordResult, invalidateTransport: Bool
    ) {
        lock.lock()
        guard passwordRequest != nil, let completion = passwordCompletion else {
            lock.unlock()
            return
        }
        state = .failed
        passwordRequest = nil
        passwordCompletion = nil
        negotiatedWireVersion = nil
        lock.unlock()
        if invalidateTransport { transport.invalidate() }
        completion(result)
    }

    func failReadyEventStart(
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity, afterEventID: UInt64,
        completion: @escaping EventCompletion
    ) {
        lock.lock()
        guard state == .ready(peerIdentity, lastEventID: afterEventID) else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        state = .failed
        negotiatedWireVersion = nil
        let commandObserver = self.commandObserver
        self.commandObserver = nil
        pendingCommand = nil
        refreshCommandResult = nil
        lock.unlock()
        transport.invalidate()
        completion(.invalidResponse)
        commandObserver?(.resultUnknown)
    }

    func finishCommandAcceptance(
        result: HostAgentXPCSnapshotClientCommandResult, invalidateTransport: Bool
    ) {
        lock.lock()
        guard case .submitting = pendingCommand, let commandObserver else {
            lock.unlock()
            return
        }
        state = .failed
        pendingCommand = nil
        self.commandObserver = nil
        negotiatedWireVersion = nil
        lock.unlock()

        if invalidateTransport { transport.invalidate() }
        commandObserver(result)
    }

    func finishPending(
        state terminalState: HostAgentXPCSnapshotClientState,
        result: HostAgentXPCSnapshotClientResult, invalidateTransport: Bool
    ) {
        lock.lock()
        guard completion != nil else {
            lock.unlock()
            return
        }
        state = terminalState
        handshakeRequest = nil
        snapshotRequest = nil
        negotiatedWireVersion = nil
        let completion = self.completion
        self.completion = nil
        lock.unlock()

        if invalidateTransport { transport.invalidate() }
        completion?(result)
    }

    func finishEventPending(
        state terminalState: HostAgentXPCSnapshotClientState,
        result: HostAgentXPCSnapshotClientEventResult, invalidateTransport: Bool,
        commandTerminalResult: HostAgentXPCSnapshotClientCommandResult = .resultUnknown
    ) {
        lock.lock()
        guard eventCompletion != nil else {
            lock.unlock()
            return
        }
        state = terminalState
        eventRequest = nil
        snapshotRequest = nil
        refreshTrigger = nil
        refreshCommandResult = nil
        negotiatedWireVersion = nil
        let eventCompletion = self.eventCompletion
        self.eventCompletion = nil
        let commandObserver = self.commandObserver
        self.commandObserver = nil
        pendingCommand = nil
        lock.unlock()

        if invalidateTransport { transport.invalidate() }
        eventCompletion?(result)
        commandObserver?(commandTerminalResult)
    }
}
