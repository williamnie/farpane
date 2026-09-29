import CoreBridgeShim
import Foundation

extension HostAgentXPCSnapshotClient {
    func receiveHandshake(_ data: Data?, request: HostAgentXPCWireHandshakeRequest) {
        guard isAwaitingHandshake(requestID: request.requestID), let data,
            let response = try? HostAgentXPCWireHandshakeResponse.decode(data)
        else {
            if isAwaitingHandshake(requestID: request.requestID) {
                finishPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
            }
            return
        }
        switch HostAgentXPCWireHandshakeNegotiator.evaluate(response, for: request) {
        case .incompatible:
            finishPending(state: .incompatible, result: .incompatible, invalidateTransport: true)
        case .invalidResponse:
            finishPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
        case .compatible(let wireVersion):
            beginSnapshot(
                handshakeRequestID: request.requestID, response: response, wireVersion: wireVersion)
        }
    }

    func beginSnapshot(
        handshakeRequestID: String, response: HostAgentXPCWireHandshakeResponse, wireVersion: UInt64
    ) {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let request: HostAgentXPCWireSnapshotRequest
        do {
            peerIdentity = try HostAgentXPCSnapshotClientPeerIdentity(response: response)
            request = try HostAgentXPCWireSnapshotRequest(
                requestID: makeRequestID(), wireVersion: wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID, agentBootID: peerIdentity.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds())
        } catch {
            finishPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
            return
        }

        lock.lock()
        guard state == .handshaking, handshakeRequest?.requestID == handshakeRequestID else {
            lock.unlock()
            return
        }
        state = .fetchingSnapshot(peerIdentity)
        handshakeRequest = nil
        negotiatedWireVersion = wireVersion
        snapshotRequest = request
        lock.unlock()

        do {
            transport.fetchSnapshot(requestData: try request.encoded()) { [weak self] data in
                self?.receiveSnapshot(data, request: request, peerIdentity: peerIdentity)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: request.requestID)
            }
        } catch {
            finishPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
        }
    }

    func receiveSnapshot(
        _ data: Data?, request: HostAgentXPCWireSnapshotRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) {
        guard isAwaitingSnapshot(requestID: request.requestID, peerIdentity: peerIdentity),
            let data, let response = try? HostAgentXPCWireSnapshotResponse.decode(data),
            response.evaluate(for: request) == .correlated
        else {
            if isAwaitingSnapshot(requestID: request.requestID, peerIdentity: peerIdentity) {
                if isRefreshingSnapshot(requestID: request.requestID, peerIdentity: peerIdentity) {
                    finishEventPending(
                        state: .failed, result: .invalidResponse, invalidateTransport: true)
                } else {
                    finishPending(
                        state: .failed, result: .invalidResponse, invalidateTransport: true)
                }
            }
            return
        }
        if finishRefreshedSnapshot(response, request: request, peerIdentity: peerIdentity) {
            return
        }
        let transition = identityTransition(to: peerIdentity)

        lock.lock()
        guard state == .fetchingSnapshot(peerIdentity),
            snapshotRequest?.requestID == request.requestID
        else {
            lock.unlock()
            return
        }
        state = .deliveringSnapshot(peerIdentity, lastEventID: response.lastEventID)
        snapshotRequest = nil
        lock.unlock()

        if transition == .replacedPrevious { onIdentityReplacementRequired() }

        lock.lock()
        guard state == .deliveringSnapshot(peerIdentity, lastEventID: response.lastEventID) else {
            lock.unlock()
            return
        }
        state = .ready(peerIdentity, lastEventID: response.lastEventID)
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(
            .ready(snapshot: response, peerIdentity: peerIdentity, identityTransition: transition))
    }
}
