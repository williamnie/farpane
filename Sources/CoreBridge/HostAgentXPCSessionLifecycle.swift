import Foundation

package enum HostAgentXPCSessionTerminationReason:
    String,
    Equatable,
    Sendable
{
    case incompatible
    case invalidResponse
    case disconnected
    case timedOut
    case cancelled
    case invalidState
}

package enum HostAgentXPCSessionLifecycleState: Equatable, Sendable {
    case idle
    case starting
    case deliveringInitialSnapshot
    case polling(
        HostAgentXPCSnapshotClientPeerIdentity,
        lastEventID: UInt64
    )
    case failed(HostAgentXPCSessionTerminationReason)
    case cancelled
}

package protocol HostAgentXPCSessionClient:
    HostAgentXPCCommandIntentClient,
    AnyObject,
    Sendable
{
    func start(
        completion: @escaping @Sendable
            (HostAgentXPCSnapshotClientResult) -> Void
    )
    func cancel()
}

extension HostAgentXPCSnapshotClient: HostAgentXPCSessionClient {}

package protocol HostAgentXPCSessionPollingOwner:
    HostAgentXPCCommandPollingArbiter,
    AnyObject,
    Sendable
{
    @discardableResult
    func start() -> Bool
    func cancel()
    func connectionDidEnd()
}

extension HostAgentXPCEventPollingOwner: HostAgentXPCSessionPollingOwner {}

package protocol HostAgentXPCSessionProjectionSink: AnyObject, Sendable {
    func resetForIdentityReplacement()
    func publishInitialSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    )
    func publishEvents(_ response: HostAgentXPCWireEventCursorResponse)
    func publishResynchronizedSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    )
    func sessionDidTerminate(_ reason: HostAgentXPCSessionTerminationReason)
}

/// Owns one App-side snapshot-first client and, only after the initial
/// snapshot is published, its event polling and command-intent owners. It
/// deliberately has no UI/readiness policy; a typed sink is the only outward
/// projection boundary.
package final class HostAgentXPCSessionLifecycle: @unchecked Sendable {
    package typealias PollingOwnerFactory = @Sendable (
        _ onResult: @escaping HostAgentXPCEventPollingOwner.ResultObserver,
        _ onTerminal: @escaping HostAgentXPCEventPollingOwner.ResultObserver
    ) -> HostAgentXPCSessionPollingOwner

    private enum PollingTermination {
        case cancel
        case connectionEnded
    }

    private let lock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let client: HostAgentXPCSessionClient
    private let sink: HostAgentXPCSessionProjectionSink
    private let makePollingOwner: PollingOwnerFactory
    private var state: HostAgentXPCSessionLifecycleState = .idle
    private var pollingOwner: HostAgentXPCSessionPollingOwner?
    private var commandOwner: HostAgentXPCCommandIntentOwner?
    private var identityResetDelivered = false

    package static func makeProduct(
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        sink: HostAgentXPCSessionProjectionSink
    ) throws -> HostAgentXPCSessionLifecycle {
        let relay = HostAgentXPCSessionLifecycleRelay()
        let client = try HostAgentXPCSnapshotClient.makeProduct(
            previousPeerIdentity: previousPeerIdentity,
            onIdentityReplacementRequired: {
                relay.identityReplacementRequired()
            },
            onConnectionEnded: {
                relay.connectionDidEnd()
            }
        )
        let lifecycle = HostAgentXPCSessionLifecycle(
            client: client,
            sink: sink,
            makePollingOwner: { onResult, onTerminal in
                HostAgentXPCEventPollingOwner.makeProduct(
                    client: client,
                    onResult: onResult,
                    onTerminal: onTerminal
                )
            }
        )
        relay.bind(lifecycle)
        return lifecycle
    }

    package init(
        client: HostAgentXPCSessionClient,
        sink: HostAgentXPCSessionProjectionSink,
        makePollingOwner: @escaping PollingOwnerFactory
    ) {
        self.client = client
        self.sink = sink
        self.makePollingOwner = makePollingOwner
    }

    deinit {
        cancel()
    }

    package func stateSnapshot() -> HostAgentXPCSessionLifecycleState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    package func commandStateSnapshot()
        -> HostAgentXPCCommandIntentOwnerState
    {
        lock.lock()
        defer { lock.unlock() }
        return commandOwner?.stateSnapshot() ?? .idle
    }

    @discardableResult
    package func submitCommand(
        _ intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        lock.lock()
        guard case .polling = state, let commandOwner else {
            lock.unlock()
            return false
        }
        lock.unlock()
        return commandOwner.submit(intent, observer: observer)
    }

    @discardableResult
    package func retryCommand(
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        lock.lock()
        guard case .polling = state, let commandOwner else {
            lock.unlock()
            return false
        }
        lock.unlock()
        return commandOwner.retry(observer: observer)
    }

    @discardableResult
    package func start() -> Bool {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return false
        }
        state = .starting
        lock.unlock()

        client.start { [weak self] result in
            self?.initialClientDidComplete(result)
        }
        return true
    }

    package func cancel() {
        terminate(
            reason: .cancelled,
            pollingTermination: .cancel
        )
    }

    package func identityReplacementRequired() {
        lock.lock()
        guard (state == .starting || state == .deliveringInitialSnapshot),
              !identityResetDelivered
        else {
            lock.unlock()
            return
        }
        identityResetDelivered = true
        lock.unlock()
        deliveryLock.lock()
        lock.lock()
        let shouldDeliver = state == .starting
            || state == .deliveringInitialSnapshot
        lock.unlock()
        guard shouldDeliver else {
            deliveryLock.unlock()
            return
        }
        sink.resetForIdentityReplacement()
        deliveryLock.unlock()
    }

    package func connectionDidEnd() {
        terminate(
            reason: .disconnected,
            pollingTermination: .connectionEnded
        )
    }

    private func initialClientDidComplete(
        _ result: HostAgentXPCSnapshotClientResult
    ) {
        switch result {
        case .ready(let snapshot, let peerIdentity, let transition):
            publishInitialAndStartPolling(
                snapshot: snapshot,
                peerIdentity: peerIdentity,
                transition: transition
            )
        case .incompatible:
            terminate(reason: .incompatible, pollingTermination: .cancel)
        case .invalidResponse:
            terminate(reason: .invalidResponse, pollingTermination: .cancel)
        case .disconnected:
            terminate(reason: .disconnected, pollingTermination: .cancel)
        case .timedOut:
            terminate(reason: .timedOut, pollingTermination: .cancel)
        case .cancelled:
            terminate(reason: .cancelled, pollingTermination: .cancel)
        case .invalidState:
            terminate(reason: .invalidState, pollingTermination: .cancel)
        }
    }

    private func publishInitialAndStartPolling(
        snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) {
        lock.lock()
        guard state == .starting else {
            lock.unlock()
            return
        }
        state = .deliveringInitialSnapshot
        lock.unlock()

        deliveryLock.lock()
        lock.lock()
        let shouldDeliverInitial = state == .deliveringInitialSnapshot
        lock.unlock()
        if shouldDeliverInitial {
            sink.publishInitialSnapshot(
                snapshot,
                peerIdentity: peerIdentity,
                transition: transition
            )
        }
        deliveryLock.unlock()

        let owner = makePollingOwner(
            { [weak self] result in self?.pollingDidPublish(result) },
            { [weak self] result in self?.pollingDidTerminate(result) }
        )
        lock.lock()
        guard state == .deliveringInitialSnapshot else {
            lock.unlock()
            owner.cancel()
            return
        }
        pollingOwner = owner
        commandOwner = HostAgentXPCCommandIntentOwner(
            client: client,
            polling: owner,
            onInvalidationRequired: { [weak self] result in
                self?.commandArbitrationDidInvalidate(result)
            }
        )
        state = .polling(
            peerIdentity,
            lastEventID: snapshot.lastEventID
        )
        lock.unlock()

        guard owner.start() else {
            terminate(reason: .invalidState, pollingTermination: .cancel)
            return
        }
    }

    private func pollingDidPublish(
        _ result: HostAgentXPCSnapshotClientEventResult
    ) {
        switch result {
        case .events(let response):
            lock.lock()
            guard case .polling(let peerIdentity, let lastEventID) = state
            else {
                lock.unlock()
                return
            }
            let nextEventID = response.resumeAfterEventID ?? lastEventID
            state = .polling(
                peerIdentity,
                lastEventID: nextEventID
            )
            lock.unlock()
            deliveryLock.lock()
            lock.lock()
            let shouldDeliver = {
                if case .polling = state { return true }
                return false
            }()
            lock.unlock()
            if shouldDeliver { sink.publishEvents(response) }
            deliveryLock.unlock()
        case .resynchronized(let snapshot, let triggeringResponse):
            lock.lock()
            guard case .polling(let peerIdentity, _) = state else {
                lock.unlock()
                return
            }
            state = .polling(
                peerIdentity,
                lastEventID: snapshot.lastEventID
            )
            lock.unlock()
            deliveryLock.lock()
            lock.lock()
            let shouldDeliver = {
                if case .polling = state { return true }
                return false
            }()
            lock.unlock()
            if shouldDeliver {
                sink.publishResynchronizedSnapshot(
                    snapshot,
                    triggeringResponse: triggeringResponse
                )
            }
            deliveryLock.unlock()
        case .invalidResponse, .disconnected, .timedOut, .cancelled,
             .invalidState:
            pollingDidTerminate(result)
        }
    }

    private func pollingDidTerminate(
        _ result: HostAgentXPCSnapshotClientEventResult
    ) {
        let reason: HostAgentXPCSessionTerminationReason
        switch result {
        case .invalidResponse:
            reason = .invalidResponse
        case .disconnected:
            reason = .disconnected
        case .timedOut:
            reason = .timedOut
        case .cancelled:
            reason = .cancelled
        case .invalidState:
            reason = .invalidState
        case .events, .resynchronized:
            reason = .invalidResponse
        }
        terminate(reason: reason, pollingTermination: .cancel)
    }

    private func commandArbitrationDidInvalidate(
        _ result: HostAgentXPCSnapshotClientCommandResult
    ) {
        let reason: HostAgentXPCSessionTerminationReason
        switch result {
        case .invalidResponse:
            reason = .invalidResponse
        case .disconnected:
            reason = .disconnected
        case .acceptanceTimedOut:
            reason = .timedOut
        case .cancelled:
            reason = .cancelled
        case .invalidState, .accepted, .completed, .resultUnknown,
             .invalidRequest, .resultTimedOut:
            reason = .invalidState
        }
        terminate(reason: reason, pollingTermination: .cancel)
    }

    private func terminate(
        reason: HostAgentXPCSessionTerminationReason,
        pollingTermination: PollingTermination
    ) {
        lock.lock()
        switch state {
        case .idle, .starting, .deliveringInitialSnapshot, .polling:
            state = reason == .cancelled ? .cancelled : .failed(reason)
        case .failed, .cancelled:
            lock.unlock()
            return
        }
        let pollingOwner = self.pollingOwner
        let commandOwner = self.commandOwner
        self.pollingOwner = nil
        self.commandOwner = nil
        lock.unlock()

        commandOwner?.cancel()
        switch pollingTermination {
        case .cancel:
            pollingOwner?.cancel()
        case .connectionEnded:
            pollingOwner?.connectionDidEnd()
        }
        client.cancel()
        deliveryLock.lock()
        sink.sessionDidTerminate(reason)
        deliveryLock.unlock()
    }
}

private final class HostAgentXPCSessionLifecycleRelay:
    @unchecked Sendable
{
    private let lock = NSLock()
    private weak var lifecycle: HostAgentXPCSessionLifecycle?

    func bind(_ lifecycle: HostAgentXPCSessionLifecycle) {
        lock.lock()
        self.lifecycle = lifecycle
        lock.unlock()
    }

    func identityReplacementRequired() {
        lockedLifecycle()?.identityReplacementRequired()
    }

    func connectionDidEnd() {
        lockedLifecycle()?.connectionDidEnd()
    }

    private func lockedLifecycle() -> HostAgentXPCSessionLifecycle? {
        lock.lock()
        defer { lock.unlock() }
        return lifecycle
    }
}
