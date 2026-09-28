import CoreBridgeShim
import Foundation

package final class HostAgentXPCSnapshotClient: @unchecked Sendable {
    package typealias Completion = @Sendable (HostAgentXPCSnapshotClientResult) -> Void
    package typealias RequestIDSource = @Sendable () -> String
    package typealias EventCompletion = @Sendable (HostAgentXPCSnapshotClientEventResult) -> Void
    package typealias CommandObserver = @Sendable (HostAgentXPCSnapshotClientCommandResult) -> Void
    package typealias PasswordCompletion =
        @Sendable (HostAgentXPCSnapshotClientPasswordResult) -> Void
    package typealias Clock = @Sendable () -> UInt64
    package typealias TimeoutScheduler =
        @Sendable (_ milliseconds: UInt64, _ action: @escaping @Sendable () -> Void) -> Void

    package static let requestTimeoutMilliseconds: UInt64 = 5_000
    package static let commandResultTimeoutMilliseconds: UInt64 = 30_000

    enum PendingCommand: Equatable {
        case submitting(
            request: HostAgentXPCWireCommandRequest,
            peerIdentity: HostAgentXPCSnapshotClientPeerIdentity, lastEventID: UInt64)
        case awaitingResult(request: HostAgentXPCWireCommandRequest)
    }

    enum CommandResultInspection {
        case none
        case matching(HostAgentXPCWireCommandResult)
        case conflicting

        var matchingResult: HostAgentXPCWireCommandResult? {
            guard case .matching(let result) = self else { return nil }
            return result
        }
    }

    struct CommandDelivery {
        let observer: CommandObserver
        let result: HostAgentXPCWireCommandResult
    }

    let lock = NSLock()
    let appBuildID: String
    let previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?
    let transport: HostAgentXPCSnapshotClientTransport
    let makeRequestID: RequestIDSource
    let nowUnixMilliseconds: Clock
    let scheduleTimeout: TimeoutScheduler
    let onIdentityReplacementRequired: @Sendable () -> Void
    let onConnectionEnded: @Sendable () -> Void
    var state: HostAgentXPCSnapshotClientState = .idle
    var completion: Completion?
    var eventCompletion: EventCompletion?
    var commandObserver: CommandObserver?
    var passwordCompletion: PasswordCompletion?
    var negotiatedWireVersion: UInt64?
    var handshakeRequest: HostAgentXPCWireHandshakeRequest?
    var snapshotRequest: HostAgentXPCWireSnapshotRequest?
    var eventRequest: HostAgentXPCWireEventCursorRequest?
    var refreshTrigger: HostAgentXPCWireEventCursorResponse?
    var pendingCommand: PendingCommand?
    var passwordRequest: HostAgentXPCWirePasswordRequest?
    var refreshCommandResult: HostAgentXPCWireCommandResult?

    package static func makeProduct(
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        onIdentityReplacementRequired: @escaping @Sendable () -> Void,
        onConnectionEnded: @escaping @Sendable () -> Void
    ) throws -> HostAgentXPCSnapshotClient {
        let bundleIdentity = try HostAgentRegistrationBundlePreflight.inspectMainBundle()
        return try HostAgentXPCSnapshotClient(
            appBuildID: bundleIdentity.buildIdentifier, previousPeerIdentity: previousPeerIdentity,
            transport: HostAgentXPCSnapshotClientConnectionTransport.makeProduct(),
            makeRequestID: productRequestID, nowUnixMilliseconds: productClock,
            scheduleTimeout: productTimeoutScheduler,
            onIdentityReplacementRequired: onIdentityReplacementRequired,
            onConnectionEnded: onConnectionEnded)
    }

    package init(
        appBuildID: String, previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        transport: HostAgentXPCSnapshotClientTransport, makeRequestID: @escaping RequestIDSource,
        nowUnixMilliseconds: @escaping Clock,
        scheduleTimeout: @escaping TimeoutScheduler = { _, _ in },
        onIdentityReplacementRequired: @escaping @Sendable () -> Void,
        onConnectionEnded: @escaping @Sendable () -> Void = {}
    ) throws {
        guard HostAgentRegistrationBundlePreflight.validBuildIdentifier(appBuildID) else {
            throw HostAgentXPCSnapshotClientConfigurationError.invalidAppBuildID
        }
        self.appBuildID = appBuildID
        self.previousPeerIdentity = previousPeerIdentity
        self.transport = transport
        self.makeRequestID = makeRequestID
        self.nowUnixMilliseconds = nowUnixMilliseconds
        self.scheduleTimeout = scheduleTimeout
        self.onIdentityReplacementRequired = onIdentityReplacementRequired
        self.onConnectionEnded = onConnectionEnded
    }

    package func stateSnapshot() -> HostAgentXPCSnapshotClientState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    package func commandStateSnapshot() -> HostAgentXPCSnapshotClientCommandState {
        lock.lock()
        defer { lock.unlock() }
        switch pendingCommand {
        case .none: return .idle
        case .submitting(let request, _, _): return .submitting(commandID: request.commandID)
        case .awaitingResult(let request): return .awaitingResult(commandID: request.commandID)
        }
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
                requestID: makeRequestID(), appBuildID: appBuildID,
                knownHostInstanceID: previousPeerIdentity?.hostInstanceID,
                knownAgentBootID: previousPeerIdentity?.agentBootID,
                knownAgentProcessID: previousPeerIdentity?.agentProcessID,
                knownAgentProcessStartIdentitySHA256: previousPeerIdentity?
                    .agentProcessStartIdentitySHA256, sentAtUnixMilliseconds: nowUnixMilliseconds())
        } catch {
            finishPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
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
            onInvalidation: { [weak self] in self?.transportDidEnd() })
        lock.lock()
        let shouldSend = state == .handshaking && handshakeRequest?.requestID == request.requestID
        lock.unlock()
        guard shouldSend else { return }

        do {
            transport.performHandshake(requestData: try request.encoded()) { [weak self] data in
                self?.receiveHandshake(data, request: request)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: request.requestID)
            }
        } catch {
            finishPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
        }
    }

    package func fetchEvents(completion: @escaping EventCompletion) {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let afterEventID: UInt64
        let wireVersion: UInt64
        lock.lock()
        guard case .ready(let peer, let cursor) = state, let negotiatedWireVersion else {
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
                requestID: makeRequestID(), wireVersion: wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID, agentBootID: peerIdentity.agentBootID,
                afterEventID: afterEventID,
                maximumEventCount: HostAgentXPCWireEventContract.maximumEventCount,
                sentAtUnixMilliseconds: nowUnixMilliseconds())
        } catch {
            failReadyEventStart(
                peerIdentity: peerIdentity, afterEventID: afterEventID, completion: completion)
            return
        }

        lock.lock()
        guard state == .ready(peerIdentity, lastEventID: afterEventID),
            negotiatedWireVersion == wireVersion
        else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        state = .fetchingEvents(peerIdentity, afterEventID: afterEventID)
        eventRequest = request
        eventCompletion = completion
        lock.unlock()

        do {
            transport.fetchEvents(requestData: try request.encoded()) { [weak self] data in
                self?.receiveEvents(data, request: request, peerIdentity: peerIdentity)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.requestDidTimeOut(requestID: request.requestID)
            }
        } catch {
            finishEventPending(state: .failed, result: .invalidResponse, invalidateTransport: true)
        }
    }

    /// Sends one semantic command on the already snapshot-gated connection.
    /// The observer first receives the correlated queued acknowledgement, then
    /// completes only when the same command ID appears in a typed event batch.
    package func submitCommand(
        commandID: String, name: HostAgentXPCWireCommandName, connectionID: String,
        observer: @escaping CommandObserver
    ) {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let lastEventID: UInt64
        let wireVersion: UInt64
        lock.lock()
        guard case .ready(let peer, let cursor) = state, pendingCommand == nil,
            let negotiatedWireVersion
        else {
            lock.unlock()
            observer(.invalidState)
            return
        }
        peerIdentity = peer
        lastEventID = cursor
        wireVersion = negotiatedWireVersion
        lock.unlock()

        let request: HostAgentXPCWireCommandRequest
        do {
            request = try HostAgentXPCWireCommandRequest(
                requestID: makeRequestID(), commandID: commandID, wireVersion: wireVersion,
                hostInstanceID: peerIdentity.hostInstanceID, agentBootID: peerIdentity.agentBootID,
                name: name, connectionID: connectionID,
                sentAtUnixMilliseconds: nowUnixMilliseconds())
        } catch {
            observer(.invalidRequest)
            return
        }

        lock.lock()
        guard state == .ready(peerIdentity, lastEventID: lastEventID), pendingCommand == nil,
            negotiatedWireVersion == wireVersion
        else {
            lock.unlock()
            observer(.invalidState)
            return
        }
        state = .submittingCommand(
            peerIdentity, lastEventID: lastEventID, commandID: request.commandID)
        pendingCommand = .submitting(
            request: request, peerIdentity: peerIdentity, lastEventID: lastEventID)
        commandObserver = observer
        lock.unlock()

        do {
            transport.submitCommand(requestData: try request.encoded()) { [weak self] data in
                self?.receiveCommandAcceptance(data, request: request)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.commandAcceptanceDidTimeOut(requestID: request.requestID)
            }
        } catch { finishCommandAcceptance(result: .invalidResponse, invalidateTransport: true) }
    }

    package func performPasswordOperation(
        action: HostAgentXPCPasswordAction, secretData: Data?,
        completion: @escaping PasswordCompletion
    ) {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let lastEventID: UInt64
        let wireVersion: UInt64
        lock.lock()
        guard case .ready(let peer, let cursor) = state, let negotiatedWireVersion,
            passwordRequest == nil
        else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        peerIdentity = peer
        lastEventID = cursor
        wireVersion = negotiatedWireVersion
        lock.unlock()

        let request: HostAgentXPCWirePasswordRequest
        do {
            request = try HostAgentXPCWirePasswordRequest(
                wireVersion: wireVersion, requestID: makeRequestID(),
                hostInstanceID: peerIdentity.hostInstanceID, agentBootID: peerIdentity.agentBootID,
                sentAtUnixMilliseconds: nowUnixMilliseconds(), action: action,
                secretLength: UInt64(secretData?.count ?? 0))
        } catch {
            completion(.invalidRequest)
            return
        }

        lock.lock()
        guard state == .ready(peerIdentity, lastEventID: lastEventID),
            negotiatedWireVersion == wireVersion, passwordRequest == nil
        else {
            lock.unlock()
            completion(.invalidState)
            return
        }
        state = .performingPasswordOperation(
            peerIdentity, lastEventID: lastEventID, requestID: request.requestID)
        passwordRequest = request
        passwordCompletion = completion
        lock.unlock()

        do {
            transport.performPasswordOperation(
                requestData: try request.encoded(), secretData: secretData
            ) { [weak self] response, secret in
                self?.receivePasswordOperation(
                    response, secret: secret, request: request, peerIdentity: peerIdentity,
                    lastEventID: lastEventID)
            }
            scheduleTimeout(Self.requestTimeoutMilliseconds) { [weak self] in
                self?.passwordOperationDidTimeOut(requestID: request.requestID)
            }
        } catch { finishPasswordOperation(result: .invalidResponse, invalidateTransport: true) }
    }

    package func cancel() {
        var initialCompletion: Completion?
        var eventCompletion: EventCompletion?
        var commandObserver: CommandObserver?
        var passwordCompletion: PasswordCompletion?
        var shouldInvalidate = false
        lock.lock()
        switch state {
        case .idle: state = .cancelled
        case .handshaking, .fetchingSnapshot, .deliveringSnapshot:
            state = .cancelled
            initialCompletion = completion
            self.completion = nil
            shouldInvalidate = true
        case .fetchingEvents, .refreshingSnapshot:
            state = .cancelled
            eventCompletion = self.eventCompletion
            self.eventCompletion = nil
            shouldInvalidate = true
        case .performingPasswordOperation:
            state = .cancelled
            passwordCompletion = self.passwordCompletion
            self.passwordCompletion = nil
            shouldInvalidate = true
        case .submittingCommand, .ready:
            state = .cancelled
            shouldInvalidate = true
        default:
            lock.unlock()
            return
        }
        commandObserver = self.commandObserver
        self.commandObserver = nil
        handshakeRequest = nil
        snapshotRequest = nil
        eventRequest = nil
        refreshTrigger = nil
        refreshCommandResult = nil
        pendingCommand = nil
        passwordRequest = nil
        negotiatedWireVersion = nil
        lock.unlock()

        if shouldInvalidate { transport.invalidate() }
        initialCompletion?(.cancelled)
        eventCompletion?(.cancelled)
        commandObserver?(.cancelled)
        passwordCompletion?(.cancelled)
    }

    static let productRequestID: RequestIDSource = { UUID().uuidString.lowercased() }

    static let productClock: Clock = {
        let milliseconds = Date().timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > 0, milliseconds <= 9_007_199_254_740_991 else {
            return 0
        }
        return UInt64(milliseconds.rounded(.towardZero))
    }

    static let productTimeoutScheduler: TimeoutScheduler = { milliseconds, action in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .milliseconds(Int(milliseconds)), execute: action)
    }
}
