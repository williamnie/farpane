import Foundation

package enum HostAgentXPCPasswordOperationResult: Equatable, Sendable {
    case succeeded(temporaryPassword: String?)
    case rejected(HostAgentXPCPasswordDetail)
    case failed(HostAgentXPCPasswordDetail)
    case unavailable
    case cancelled
}

/// Owns one fresh authenticated, snapshot-first XPC connection for one
/// credential operation. It never shares the long-lived event-polling client,
/// so password actions cannot race its selector state.
package final class HostAgentXPCPasswordOperationOwner: @unchecked Sendable {
    package typealias Completion = @Sendable
        (HostAgentXPCPasswordOperationResult) -> Void

    private let lock = NSLock()
    private let client: HostAgentXPCSnapshotClient
    private let expectedPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    private let action: HostAgentXPCPasswordAction
    private var secretData: Data
    private var completion: Completion?
    private var started = false
    private var finished = false

    package static func makeProduct(
        expectedPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        action: HostAgentXPCPasswordAction,
        secretData: Data = Data()
    ) throws -> HostAgentXPCPasswordOperationOwner {
        let client = try HostAgentXPCSnapshotClient.makeProduct(
            previousPeerIdentity: expectedPeerIdentity,
            onIdentityReplacementRequired: {},
            onConnectionEnded: {}
        )
        return HostAgentXPCPasswordOperationOwner(
            client: client,
            expectedPeerIdentity: expectedPeerIdentity,
            action: action,
            secretData: secretData
        )
    }

    package init(
        client: HostAgentXPCSnapshotClient,
        expectedPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        action: HostAgentXPCPasswordAction,
        secretData: Data = Data()
    ) {
        self.client = client
        self.expectedPeerIdentity = expectedPeerIdentity
        self.action = action
        self.secretData = secretData
    }

    deinit { cancel() }

    @discardableResult
    package func start(completion: @escaping Completion) -> Bool {
        lock.lock()
        guard !started, !finished else {
            lock.unlock()
            return false
        }
        started = true
        self.completion = completion
        lock.unlock()

        client.start { [weak self] result in
            self?.clientDidStart(result)
        }
        return true
    }

    package func cancel() {
        let completion: Completion?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        completion = self.completion
        self.completion = nil
        wipeSecretLocked()
        lock.unlock()
        client.cancel()
        completion?(.cancelled)
    }

    private func clientDidStart(_ result: HostAgentXPCSnapshotClientResult) {
        guard case .ready(_, let peerIdentity, _) = result,
              peerIdentity == expectedPeerIdentity
        else {
            finish(.unavailable)
            return
        }
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let secret = secretData
        lock.unlock()
        client.performPasswordOperation(
            action: action,
            secretData: secret.isEmpty ? nil : secret
        ) { [weak self] result in
            self?.passwordOperationDidComplete(result)
        }
    }

    private func passwordOperationDidComplete(
        _ result: HostAgentXPCSnapshotClientPasswordResult
    ) {
        switch result {
        case .completed(let response, let secret):
            switch response.status {
            case .ok:
                if response.action == .revealTemporaryPassword {
                    guard let secret,
                          let password = String(data: secret, encoding: .utf8),
                          !password.isEmpty,
                          !password.unicodeScalars.contains(
                            where: CharacterSet.controlCharacters.contains
                          )
                    else {
                        finish(.failed(.temporaryPasswordUnavailable))
                        return
                    }
                    finish(.succeeded(temporaryPassword: password))
                } else {
                    finish(.succeeded(temporaryPassword: nil))
                }
            case .rejected:
                finish(.rejected(response.detail))
            case .error:
                finish(.failed(response.detail))
            }
        case .cancelled:
            finish(.cancelled)
        case .invalidRequest, .invalidResponse, .disconnected, .timedOut,
             .invalidState:
            finish(.unavailable)
        }
    }

    private func finish(_ result: HostAgentXPCPasswordOperationResult) {
        let completion: Completion?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        completion = self.completion
        self.completion = nil
        wipeSecretLocked()
        lock.unlock()
        client.cancel()
        completion?(result)
    }

    private func wipeSecretLocked() {
        guard !secretData.isEmpty else { return }
        secretData.resetBytes(in: 0..<secretData.count)
        secretData.removeAll(keepingCapacity: false)
    }
}
