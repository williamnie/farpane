import CoreBridgeShim
import Foundation

package enum HostAgentXPCSnapshotClientConfigurationError: Error, Equatable {
    case invalidAppBuildID
    case invalidPeerIdentity
}

package struct HostAgentXPCSnapshotClientPeerIdentity: Equatable, Sendable {
    package let agentBuildID: String
    package let hostInstanceID: String
    package let agentBootID: String

    package init(
        agentBuildID: String,
        hostInstanceID: String,
        agentBootID: String
    ) throws {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
                agentBuildID
              ),
              HostAgentXPCWireHandshakeContract.validIdentifier(hostInstanceID),
              HostAgentXPCWireHandshakeContract.validCanonicalUUID(agentBootID)
        else {
            throw HostAgentXPCSnapshotClientConfigurationError
                .invalidPeerIdentity
        }
        self.agentBuildID = agentBuildID
        self.hostInstanceID = hostInstanceID
        self.agentBootID = agentBootID
    }

    fileprivate init(
        response: HostAgentXPCWireHandshakeResponse
    ) throws {
        try self.init(
            agentBuildID: response.agentBuildID,
            hostInstanceID: response.hostInstanceID,
            agentBootID: response.agentBootID
        )
    }
}

package enum HostAgentXPCSnapshotClientIdentityTransition: Equatable, Sendable {
    case firstObservation
    case unchanged
    case replacedPrevious
}

package enum HostAgentXPCSnapshotClientResult: Equatable, Sendable {
    case ready(
        snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        identityTransition: HostAgentXPCSnapshotClientIdentityTransition
    )
    case incompatible
    case invalidResponse
    case disconnected
    case timedOut
    case cancelled
    case invalidState
}

package enum HostAgentXPCSnapshotClientState: Equatable, Sendable {
    case idle
    case handshaking
    case fetchingSnapshot(HostAgentXPCSnapshotClientPeerIdentity)
    case deliveringSnapshot(
        HostAgentXPCSnapshotClientPeerIdentity,
        lastEventID: UInt64
    )
    case ready(
        HostAgentXPCSnapshotClientPeerIdentity,
        lastEventID: UInt64
    )
    case incompatible
    case failed
    case disconnected
    case cancelled
}

package protocol HostAgentXPCSnapshotClientTransport: AnyObject, Sendable {
    func start(
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    )
    func performHandshake(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    )
    func fetchSnapshot(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    )
    func invalidate()
}

package final class HostAgentXPCSnapshotClientConnectionTransport:
    HostAgentXPCSnapshotClientTransport,
    @unchecked Sendable
{
    private let connection: NSXPCConnection
    private let interface: NSXPCInterface

    package static func makeProduct()
        -> HostAgentXPCSnapshotClientConnectionTransport
    {
        let connection = NSXPCConnection(
            machServiceName: HostAgentXPCListenerFactory.machServiceName,
            options: []
        )
        return HostAgentXPCSnapshotClientConnectionTransport(
            connection: connection
        )
    }

    package init(connection: NSXPCConnection) {
        self.connection = connection
        interface = HostAgentXPCSnapshotInterfaceFactory.makeInterface()
    }

    package func start(
        onInterruption: @escaping @Sendable () -> Void,
        onInvalidation: @escaping @Sendable () -> Void
    ) {
        connection.remoteObjectInterface = interface
        connection.interruptionHandler = onInterruption
        connection.invalidationHandler = onInvalidation
        connection.resume()
    }

    package func performHandshake(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        invoke(reply: reply) { service, finish in
            service.performHandshake(
                requestData: requestData,
                reply: finish
            )
        }
    }

    package func fetchSnapshot(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        invoke(reply: reply) { service, finish in
            service.fetchSnapshot(
                requestData: requestData,
                reply: finish
            )
        }
    }

    package func invalidate() {
        connection.invalidate()
    }

    private func invoke(
        reply: @escaping @Sendable (Data?) -> Void,
        body: (
            RDNHostAgentXPCSnapshotService,
            @escaping (Data?) -> Void
        ) -> Void
    ) {
        let relay = HostAgentXPCSnapshotClientReplyRelay(reply: reply)
        guard let service = connection.remoteObjectProxyWithErrorHandler(
            { _ in relay.finish(nil) }
        ) as? RDNHostAgentXPCSnapshotService else {
            relay.finish(nil)
            return
        }
        body(service) { data in relay.finish(data) }
    }
}

private final class HostAgentXPCSnapshotClientReplyRelay:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var reply: (@Sendable (Data?) -> Void)?

    init(reply: @escaping @Sendable (Data?) -> Void) {
        self.reply = reply
    }

    func finish(_ data: Data?) {
        lock.lock()
        let reply = self.reply
        self.reply = nil
        lock.unlock()
        reply?(data)
    }
}

package final class HostAgentXPCSnapshotClient: @unchecked Sendable {
    package typealias Completion = @Sendable
        (HostAgentXPCSnapshotClientResult) -> Void
    package typealias RequestIDSource = @Sendable () -> String
    package typealias Clock = @Sendable () -> UInt64
    package typealias TimeoutScheduler = @Sendable (
        _ milliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> Void

    package static let requestTimeoutMilliseconds: UInt64 = 5_000

    private let lock = NSLock()
    private let appBuildID: String
    private let previousPeerIdentity:
        HostAgentXPCSnapshotClientPeerIdentity?
    private let transport: HostAgentXPCSnapshotClientTransport
    private let makeRequestID: RequestIDSource
    private let nowUnixMilliseconds: Clock
    private let scheduleTimeout: TimeoutScheduler
    private let onIdentityReplacementRequired: @Sendable () -> Void
    private let onConnectionEnded: @Sendable () -> Void
    private var state: HostAgentXPCSnapshotClientState = .idle
    private var completion: Completion?
    private var handshakeRequest: HostAgentXPCWireHandshakeRequest?
    private var snapshotRequest: HostAgentXPCWireSnapshotRequest?

    package static func makeProduct(
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        onIdentityReplacementRequired: @escaping @Sendable () -> Void,
        onConnectionEnded: @escaping @Sendable () -> Void
    ) throws -> HostAgentXPCSnapshotClient {
        let bundleIdentity = try
            HostAgentRegistrationBundlePreflight.inspectMainBundle()
        return try HostAgentXPCSnapshotClient(
            appBuildID: bundleIdentity.buildIdentifier,
            previousPeerIdentity: previousPeerIdentity,
            transport:
                HostAgentXPCSnapshotClientConnectionTransport.makeProduct(),
            makeRequestID: productRequestID,
            nowUnixMilliseconds: productClock,
            scheduleTimeout: productTimeoutScheduler,
            onIdentityReplacementRequired: onIdentityReplacementRequired,
            onConnectionEnded: onConnectionEnded
        )
    }

    package init(
        appBuildID: String,
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        transport: HostAgentXPCSnapshotClientTransport,
        makeRequestID: @escaping RequestIDSource,
        nowUnixMilliseconds: @escaping Clock,
        scheduleTimeout: @escaping TimeoutScheduler = { _, _ in },
        onIdentityReplacementRequired: @escaping @Sendable () -> Void,
        onConnectionEnded: @escaping @Sendable () -> Void = {}
    ) throws {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(
            appBuildID
        ) else {
            throw HostAgentXPCSnapshotClientConfigurationError
                .invalidAppBuildID
        }
        self.appBuildID = appBuildID
        self.previousPeerIdentity = previousPeerIdentity
        self.transport = transport
        self.makeRequestID = makeRequestID
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.scheduleTimeout = scheduleTimeout
        self.onIdentityReplacementRequired =
            onIdentityReplacementRequired
        self.onConnectionEnded = onConnectionEnded
    }

    package func stateSnapshot() -> HostAgentXPCSnapshotClientState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    package func start(completion: @escaping Completion) {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        state = .handshaking
        self.completion = completion
        lock.unlock()

        let request: HostAgentXPCWireHandshakeRequest
        do {
            request = try HostAgentXPCWireHandshakeRequest.makeProductRequest(
                requestID: makeRequestID(),
                appBuildID: appBuildID,
                knownHostInstanceID: previousPeerIdentity?.hostInstanceID,
                knownAgentBootID: previousPeerIdentity?.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
        } catch {
            finishPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
            return
        }

        lock.lock()
        guard state == .handshaking else {
            lock.unlock()
            return
        }
        handshakeRequest = request
        lock.unlock()

        transport.start(
            onInterruption: { [weak self] in self?.transportDidEnd() },
            onInvalidation: { [weak self] in self?.transportDidEnd() }
        )
        lock.lock()
        let shouldSend = state == .handshaking
            && handshakeRequest?.requestID == request.requestID
        lock.unlock()
        guard shouldSend else { return }

        do {
            transport.performHandshake(requestData: try request.encoded()) {
                [weak self] data in
                self?.receiveHandshake(data, request: request)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: request.requestID)
            }
        } catch {
            finishPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
        }
    }

    package func cancel() {
        lock.lock()
        switch state {
        case .idle:
            state = .cancelled
            lock.unlock()
        case .handshaking, .fetchingSnapshot, .deliveringSnapshot:
            state = .cancelled
            handshakeRequest = nil
            snapshotRequest = nil
            let completion = self.completion
            self.completion = nil
            lock.unlock()
            transport.invalidate()
            completion?(.cancelled)
        case .ready:
            state = .cancelled
            lock.unlock()
            transport.invalidate()
        default:
            lock.unlock()
        }
    }

    private func receiveHandshake(
        _ data: Data?,
        request: HostAgentXPCWireHandshakeRequest
    ) {
        guard isAwaitingHandshake(requestID: request.requestID),
              let data,
              let response = try? HostAgentXPCWireHandshakeResponse.decode(data)
        else {
            if isAwaitingHandshake(requestID: request.requestID) {
                finishPending(
                    state: .failed,
                    result: .invalidResponse,
                    invalidateTransport: true
                )
            }
            return
        }
        switch HostAgentXPCWireHandshakeNegotiator.evaluate(
            response,
            for: request
        ) {
        case .incompatible:
            finishPending(
                state: .incompatible,
                result: .incompatible,
                invalidateTransport: true
            )
        case .invalidResponse:
            finishPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
        case .compatible(let wireVersion):
            beginSnapshot(
                handshakeRequestID: request.requestID,
                response: response,
                wireVersion: wireVersion
            )
        }
    }

    private func beginSnapshot(
        handshakeRequestID: String,
        response: HostAgentXPCWireHandshakeResponse,
        wireVersion: UInt64
    ) {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let request: HostAgentXPCWireSnapshotRequest
        do {
            peerIdentity = try HostAgentXPCSnapshotClientPeerIdentity(
                response: response
            )
            request = try HostAgentXPCWireSnapshotRequest(
                requestID: makeRequestID(),
                wireVersion: wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID,
                agentBootID: peerIdentity.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
        } catch {
            finishPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
            return
        }

        lock.lock()
        guard state == .handshaking,
              handshakeRequest?.requestID == handshakeRequestID
        else {
            lock.unlock()
            return
        }
        state = .fetchingSnapshot(peerIdentity)
        handshakeRequest = nil
        snapshotRequest = request
        lock.unlock()

        do {
            transport.fetchSnapshot(requestData: try request.encoded()) {
                [weak self] data in
                self?.receiveSnapshot(
                    data,
                    request: request,
                    peerIdentity: peerIdentity
                )
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: request.requestID)
            }
        } catch {
            finishPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
        }
    }

    private func receiveSnapshot(
        _ data: Data?,
        request: HostAgentXPCWireSnapshotRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) {
        guard isAwaitingSnapshot(
                requestID: request.requestID,
                peerIdentity: peerIdentity
              ),
              let data,
              let response = try? HostAgentXPCWireSnapshotResponse.decode(data),
              response.evaluate(for: request) == .correlated
        else {
            if isAwaitingSnapshot(
                requestID: request.requestID,
                peerIdentity: peerIdentity
            ) {
                finishPending(
                    state: .failed,
                    result: .invalidResponse,
                    invalidateTransport: true
                )
            }
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
        state = .deliveringSnapshot(
            peerIdentity,
            lastEventID: response.lastEventID
        )
        snapshotRequest = nil
        lock.unlock()

        if transition == .replacedPrevious {
            onIdentityReplacementRequired()
        }

        lock.lock()
        guard state == .deliveringSnapshot(
            peerIdentity,
            lastEventID: response.lastEventID
        ) else {
            lock.unlock()
            return
        }
        state = .ready(peerIdentity, lastEventID: response.lastEventID)
        let completion = self.completion
        self.completion = nil
        lock.unlock()
        completion?(.ready(
            snapshot: response,
            peerIdentity: peerIdentity,
            identityTransition: transition
        ))
    }

    private func identityTransition(
        to peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> HostAgentXPCSnapshotClientIdentityTransition {
        guard let previousPeerIdentity else { return .firstObservation }
        guard previousPeerIdentity == peerIdentity
        else { return .replacedPrevious }
        return .unchanged
    }

    private func requestDidTimeOut(requestID: String) {
        lock.lock()
        let isCurrent = handshakeRequest?.requestID == requestID
            || snapshotRequest?.requestID == requestID
        lock.unlock()
        guard isCurrent else { return }
        finishPending(
            state: .failed,
            result: .timedOut,
            invalidateTransport: true
        )
    }

    private func transportDidEnd() {
        lock.lock()
        switch state {
        case .handshaking, .fetchingSnapshot, .deliveringSnapshot:
            state = .disconnected
            handshakeRequest = nil
            snapshotRequest = nil
            let completion = self.completion
            self.completion = nil
            lock.unlock()
            completion?(.disconnected)
        case .ready:
            state = .disconnected
            lock.unlock()
            onConnectionEnded()
        default:
            lock.unlock()
        }
    }

    private func isAwaitingHandshake(requestID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .handshaking
            && handshakeRequest?.requestID == requestID
    }

    private func isAwaitingSnapshot(
        requestID: String,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .fetchingSnapshot(peerIdentity)
            && snapshotRequest?.requestID == requestID
    }

    private func finishPending(
        state terminalState: HostAgentXPCSnapshotClientState,
        result: HostAgentXPCSnapshotClientResult,
        invalidateTransport: Bool
    ) {
        lock.lock()
        guard completion != nil else {
            lock.unlock()
            return
        }
        state = terminalState
        handshakeRequest = nil
        snapshotRequest = nil
        let completion = self.completion
        self.completion = nil
        lock.unlock()

        if invalidateTransport { transport.invalidate() }
        completion?(result)
    }

    private static let productRequestID: RequestIDSource = {
        UUID().uuidString.lowercased()
    }

    private static let productClock: Clock = {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
              milliseconds > 0,
              milliseconds <= 9_007_199_254_740_991
        else { return 0 }
        return UInt64(milliseconds.rounded(.towardZero))
    }

    private static let productTimeoutScheduler: TimeoutScheduler = {
        milliseconds,
        action in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(Int(milliseconds)),
            execute: action
        )
    }
}
