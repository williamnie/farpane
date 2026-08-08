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

package enum HostAgentXPCSnapshotClientEventResult: Equatable, Sendable {
    case events(HostAgentXPCWireEventCursorResponse)
    case resynchronized(
        snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    )
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
    case fetchingEvents(
        HostAgentXPCSnapshotClientPeerIdentity,
        afterEventID: UInt64
    )
    case refreshingSnapshot(
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
    func fetchEvents(
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

    package func fetchEvents(
        requestData: Data,
        reply: @escaping @Sendable (Data?) -> Void
    ) {
        invoke(reply: reply) { service, finish in
            service.fetchEvents(
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
            RDNHostAgentXPCEventService,
            @escaping (Data?) -> Void
        ) -> Void
    ) {
        let relay = HostAgentXPCSnapshotClientReplyRelay(reply: reply)
        guard let service = connection.remoteObjectProxyWithErrorHandler(
            { _ in relay.finish(nil) }
        ) as? RDNHostAgentXPCEventService else {
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
    package typealias EventCompletion = @Sendable
        (HostAgentXPCSnapshotClientEventResult) -> Void
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
    private var eventCompletion: EventCompletion?
    private var negotiatedWireVersion: UInt64?
    private var handshakeRequest: HostAgentXPCWireHandshakeRequest?
    private var snapshotRequest: HostAgentXPCWireSnapshotRequest?
    private var eventRequest: HostAgentXPCWireEventCursorRequest?
    private var refreshTrigger: HostAgentXPCWireEventCursorResponse?

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

    package func fetchEvents(completion: @escaping EventCompletion) {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let afterEventID: UInt64
        let wireVersion: UInt64
        lock.lock()
        guard case .ready(let peer, let cursor) = state,
              let negotiatedWireVersion
        else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        peerIdentity = peer
        afterEventID = cursor
        wireVersion = negotiatedWireVersion
        lock.unlock()

        let request: HostAgentXPCWireEventCursorRequest
        do {
            request = try HostAgentXPCWireEventCursorRequest(
                requestID: makeRequestID(),
                wireVersion: wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID,
                agentBootID: peerIdentity.agentBootID,
                afterEventID: afterEventID,
                maximumEventCount:
                    HostAgentXPCWireEventContract.maximumEventCount,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
        } catch {
            failReadyEventStart(
                peerIdentity: peerIdentity,
                afterEventID: afterEventID,
                completion: completion
            )
            return
        }

        lock.lock()
        guard state == .ready(
                peerIdentity,
                lastEventID: afterEventID
              ),
              negotiatedWireVersion == wireVersion
        else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        state = .fetchingEvents(
            peerIdentity,
            afterEventID: afterEventID
        )
        eventRequest = request
        eventCompletion = completion
        lock.unlock()

        do {
            transport.fetchEvents(requestData: try request.encoded()) {
                [weak self] data in
                self?.receiveEvents(
                    data,
                    request: request,
                    peerIdentity: peerIdentity
                )
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: request.requestID)
            }
        } catch {
            finishEventPending(
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
        case .fetchingEvents, .refreshingSnapshot:
            state = .cancelled
            eventRequest = nil
            snapshotRequest = nil
            refreshTrigger = nil
            let eventCompletion = self.eventCompletion
            self.eventCompletion = nil
            lock.unlock()
            transport.invalidate()
            eventCompletion?(.cancelled)
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
        negotiatedWireVersion = wireVersion
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
                if isRefreshingSnapshot(
                    requestID: request.requestID,
                    peerIdentity: peerIdentity
                ) {
                    finishEventPending(
                        state: .failed,
                        result: .invalidResponse,
                        invalidateTransport: true
                    )
                } else {
                    finishPending(
                        state: .failed,
                        result: .invalidResponse,
                        invalidateTransport: true
                    )
                }
            }
            return
        }
        if finishRefreshedSnapshot(
            response,
            request: request,
            peerIdentity: peerIdentity
        ) {
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

    private func receiveEvents(
        _ data: Data?,
        request: HostAgentXPCWireEventCursorRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) {
        guard isAwaitingEvents(
                requestID: request.requestID,
                peerIdentity: peerIdentity,
                afterEventID: request.afterEventID
              ),
              let data,
              let response = try? HostAgentXPCWireEventCursorResponse.decode(
                data
              ),
              response.evaluate(for: request) == .correlated
        else {
            if isAwaitingEvents(
                requestID: request.requestID,
                peerIdentity: peerIdentity,
                afterEventID: request.afterEventID
            ) {
                finishEventPending(
                    state: .failed,
                    result: .invalidResponse,
                    invalidateTransport: true
                )
            }
            return
        }

        if responseRequiresSnapshot(response) {
            beginEventResnapshot(
                response: response,
                request: request,
                peerIdentity: peerIdentity
            )
            return
        }

        let nextEventID: UInt64
        switch response.outcome {
        case .upToDate:
            nextEventID = request.afterEventID
        case .batch:
            guard let resumeAfterEventID = response.resumeAfterEventID else {
                finishEventPending(
                    state: .failed,
                    result: .invalidResponse,
                    invalidateTransport: true
                )
                return
            }
            nextEventID = resumeAfterEventID
        case .gap, .invalidCursor, .resnapshotRequired:
            finishEventPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
            return
        }

        lock.lock()
        guard state == .fetchingEvents(
                peerIdentity,
                afterEventID: request.afterEventID
              ),
              eventRequest?.requestID == request.requestID
        else {
            lock.unlock()
            return
        }
        state = .ready(peerIdentity, lastEventID: nextEventID)
        eventRequest = nil
        let eventCompletion = self.eventCompletion
        self.eventCompletion = nil
        lock.unlock()
        eventCompletion?(.events(response))
    }

    private func responseRequiresSnapshot(
        _ response: HostAgentXPCWireEventCursorResponse
    ) -> Bool {
        switch response.outcome {
        case .gap, .invalidCursor, .resnapshotRequired:
            return true
        case .upToDate:
            return false
        case .batch:
            return response.events.contains { event in
                if case .snapshotChanged = event.payload { return true }
                return false
            }
        }
    }

    private func beginEventResnapshot(
        response: HostAgentXPCWireEventCursorResponse,
        request: HostAgentXPCWireEventCursorRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) {
        let snapshotRequest: HostAgentXPCWireSnapshotRequest
        do {
            snapshotRequest = try HostAgentXPCWireSnapshotRequest(
                requestID: makeRequestID(),
                wireVersion: request.wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID,
                agentBootID: peerIdentity.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds()
            )
        } catch {
            finishEventPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
            return
        }

        lock.lock()
        guard state == .fetchingEvents(
                peerIdentity,
                afterEventID: request.afterEventID
              ),
              eventRequest?.requestID == request.requestID
        else {
            lock.unlock()
            return
        }
        state = .refreshingSnapshot(
            peerIdentity,
            lastEventID: request.afterEventID
        )
        eventRequest = nil
        self.snapshotRequest = snapshotRequest
        refreshTrigger = response
        lock.unlock()

        do {
            transport.fetchSnapshot(requestData: try snapshotRequest.encoded()) {
                [weak self] data in
                self?.receiveSnapshot(
                    data,
                    request: snapshotRequest,
                    peerIdentity: peerIdentity
                )
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: snapshotRequest.requestID)
            }
        } catch {
            finishEventPending(
                state: .failed,
                result: .invalidResponse,
                invalidateTransport: true
            )
        }
    }

    @discardableResult
    private func finishRefreshedSnapshot(
        _ response: HostAgentXPCWireSnapshotResponse,
        request: HostAgentXPCWireSnapshotRequest,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        lock.lock()
        guard case .refreshingSnapshot(let expectedPeer, _) = state,
              expectedPeer == peerIdentity,
              snapshotRequest?.requestID == request.requestID,
              let refreshTrigger,
              let eventCompletion
        else {
            lock.unlock()
            return false
        }
        state = .ready(peerIdentity, lastEventID: response.lastEventID)
        snapshotRequest = nil
        self.refreshTrigger = nil
        self.eventCompletion = nil
        lock.unlock()
        eventCompletion(.resynchronized(
            snapshot: response,
            triggeringResponse: refreshTrigger
        ))
        return true
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
        let isInitialRequest = completion != nil
            && (handshakeRequest?.requestID == requestID
                || snapshotRequest?.requestID == requestID)
        let isEventRequest = eventCompletion != nil
            && (eventRequest?.requestID == requestID
                || snapshotRequest?.requestID == requestID)
        lock.unlock()
        if isEventRequest {
            finishEventPending(
                state: .failed,
                result: .timedOut,
                invalidateTransport: true
            )
        } else if isInitialRequest {
            finishPending(
                state: .failed,
                result: .timedOut,
                invalidateTransport: true
            )
        }
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
        case .fetchingEvents, .refreshingSnapshot:
            state = .disconnected
            eventRequest = nil
            snapshotRequest = nil
            refreshTrigger = nil
            let eventCompletion = self.eventCompletion
            self.eventCompletion = nil
            lock.unlock()
            eventCompletion?(.disconnected)
            onConnectionEnded()
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
        switch state {
        case .fetchingSnapshot(let expectedPeer):
            return expectedPeer == peerIdentity
                && snapshotRequest?.requestID == requestID
        case .refreshingSnapshot(let expectedPeer, _):
            return expectedPeer == peerIdentity
                && snapshotRequest?.requestID == requestID
        default:
            return false
        }
    }

    private func isRefreshingSnapshot(
        requestID: String,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .refreshingSnapshot(let expectedPeer, _) = state else {
            return false
        }
        return expectedPeer == peerIdentity
            && snapshotRequest?.requestID == requestID
    }

    private func isAwaitingEvents(
        requestID: String,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        afterEventID: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .fetchingEvents(
            peerIdentity,
            afterEventID: afterEventID
        ) && eventRequest?.requestID == requestID
    }

    private func failReadyEventStart(
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        afterEventID: UInt64,
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
        lock.unlock()
        transport.invalidate()
        completion(.invalidResponse)
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
        negotiatedWireVersion = nil
        let completion = self.completion
        self.completion = nil
        lock.unlock()

        if invalidateTransport { transport.invalidate() }
        completion?(result)
    }

    private func finishEventPending(
        state terminalState: HostAgentXPCSnapshotClientState,
        result: HostAgentXPCSnapshotClientEventResult,
        invalidateTransport: Bool
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
        negotiatedWireVersion = nil
        let eventCompletion = self.eventCompletion
        self.eventCompletion = nil
        lock.unlock()

        if invalidateTransport { transport.invalidate() }
        eventCompletion?(result)
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
