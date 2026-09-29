import CoreBridgeShim
import Foundation

extension HostAgentXPCSnapshotClient {
    func receivePasswordOperation(
        _ data: Data?, secret: Data?, request: HostAgentXPCWirePasswordRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64
    ) {
        guard let data, let response = try? HostAgentXPCWirePasswordResponse.decode(data),
            response.isCorrelated(to: request), UInt64(secret?.count ?? 0) == response.secretLength
        else {
            if isAwaitingPasswordOperation(requestID: request.requestID) {
                finishPasswordOperation(result: .invalidResponse, invalidateTransport: true)
            }
            return
        }
        lock.lock()
        guard
            state
                == .performingPasswordOperation(
                    peerIdentity, lastEventID: lastEventID, requestID: request.requestID),
            passwordRequest?.requestID == request.requestID, let completion = passwordCompletion
        else {
            lock.unlock()
            return
        }
        state = .ready(peerIdentity, lastEventID: lastEventID)
        passwordRequest = nil
        passwordCompletion = nil
        lock.unlock()
        completion(.completed(response, secret: secret))
    }

    func receiveCommandAcceptance(_ data: Data?, request: HostAgentXPCWireCommandRequest) {
        guard isAwaitingCommandAcceptance(requestID: request.requestID), let data,
            let accepted = try? HostAgentXPCWireCommandAcceptedResponse.decode(data),
            accepted.evaluate(for: request) == .correlated
        else {
            if isAwaitingCommandAcceptance(requestID: request.requestID) {
                finishCommandAcceptance(result: .invalidResponse, invalidateTransport: true)
            }
            return
        }

        lock.lock()
        guard
            case .submitting(let expectedRequest, let peerIdentity, let lastEventID) =
                pendingCommand, expectedRequest.requestID == request.requestID,
            state
                == .submittingCommand(
                    peerIdentity, lastEventID: lastEventID, commandID: request.commandID),
            let commandObserver
        else {
            lock.unlock()
            return
        }
        state = .ready(peerIdentity, lastEventID: lastEventID)
        pendingCommand = .awaitingResult(request: expectedRequest)
        lock.unlock()

        commandObserver(.accepted(accepted))
        scheduleTimeout(Self.commandResultTimeoutMilliseconds) { [weak self] in
            self?.commandResultDidTimeOut(requestID: request.requestID)
        }
    }
}
