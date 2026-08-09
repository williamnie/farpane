import Foundation

package struct HostAgentXPCCommandIntent: Equatable, Sendable {
    package let commandID: String
    package let name: HostAgentXPCWireCommandName
    package let connectionID: String

    package init(
        commandID: String,
        name: HostAgentXPCWireCommandName,
        connectionID: String
    ) {
        self.commandID = commandID
        self.name = name
        self.connectionID = connectionID
    }
}

package enum HostAgentXPCCommandIntentOwnerState: Equatable, Sendable {
    case idle
    case pausing(HostAgentXPCCommandIntent)
    case awaitingAcceptance(HostAgentXPCCommandIntent)
    case awaitingResult(HostAgentXPCCommandIntent)
    case retryable(HostAgentXPCCommandIntent)
    case invalidated
    case cancelled
}

package protocol HostAgentXPCCommandIntentClient: AnyObject, Sendable {
    func submitCommand(
        commandID: String,
        name: HostAgentXPCWireCommandName,
        connectionID: String,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    )
}

extension HostAgentXPCSnapshotClient: HostAgentXPCCommandIntentClient {}

package protocol HostAgentXPCCommandPollingArbiter: AnyObject, Sendable {
    @discardableResult
    func pause(
        completion: @escaping HostAgentXPCEventPollingOwner.PauseCompletion
    ) -> Bool
    @discardableResult
    func resume(delayMilliseconds: UInt64) -> Bool
}

extension HostAgentXPCEventPollingOwner: HostAgentXPCCommandPollingArbiter {}

/// Owns one semantic App intent independently from its fresh request IDs.
/// Every attempt pauses the shared event selector until queued acceptance;
/// retryable terminal outcomes retain the exact command ID and payload.
package final class HostAgentXPCCommandIntentOwner: @unchecked Sendable {
    package typealias Observer = HostAgentXPCSnapshotClient.CommandObserver
    package typealias InvalidationCallback = @Sendable
        (HostAgentXPCSnapshotClientCommandResult) -> Void

    /// The Agent restores its per-connection state after replying. Keeping the
    /// same bounded interval as its command gate avoids racing that restoration.
    package static let acceptanceResumeDelayMilliseconds: UInt64 = 100

    private let lock = NSLock()
    private let client: HostAgentXPCCommandIntentClient
    private let polling: HostAgentXPCCommandPollingArbiter
    private let onInvalidationRequired: InvalidationCallback
    private var state: HostAgentXPCCommandIntentOwnerState = .idle
    private var observer: Observer?
    private var generation: UInt64 = 0

    package init(
        client: HostAgentXPCCommandIntentClient,
        polling: HostAgentXPCCommandPollingArbiter,
        onInvalidationRequired: @escaping InvalidationCallback
    ) {
        self.client = client
        self.polling = polling
        self.onInvalidationRequired = onInvalidationRequired
    }

    deinit {
        cancel()
    }

    package func stateSnapshot() -> HostAgentXPCCommandIntentOwnerState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    @discardableResult
    package func submit(
        _ intent: HostAgentXPCCommandIntent,
        observer: @escaping Observer
    ) -> Bool {
        beginAttempt(
            intent: intent,
            observer: observer,
            requiresRetryableState: false
        )
    }

    /// Retries only the retained intent; callers cannot accidentally change
    /// the command ID, semantic action or target after an unknown result.
    @discardableResult
    package func retry(observer: @escaping Observer) -> Bool {
        lock.lock()
        guard case .retryable(let intent) = state else {
            lock.unlock()
            return false
        }
        lock.unlock()
        return beginAttempt(
            intent: intent,
            observer: observer,
            requiresRetryableState: true
        )
    }

    package func cancel() {
        lock.lock()
        switch state {
        case .idle, .pausing, .awaitingAcceptance, .awaitingResult, .retryable:
            state = .cancelled
        case .invalidated, .cancelled:
            lock.unlock()
            return
        }
        generation &+= 1
        let observer = self.observer
        self.observer = nil
        lock.unlock()
        observer?(.cancelled)
    }

    private func beginAttempt(
        intent: HostAgentXPCCommandIntent,
        observer: @escaping Observer,
        requiresRetryableState: Bool
    ) -> Bool {
        lock.lock()
        if requiresRetryableState {
            guard state == .retryable(intent) else {
                lock.unlock()
                return false
            }
        } else {
            guard state == .idle else {
                lock.unlock()
                return false
            }
        }
        generation &+= 1
        let generation = self.generation
        state = .pausing(intent)
        self.observer = observer
        lock.unlock()

        let accepted = polling.pause { [weak self] paused in
            self?.pauseDidComplete(
                paused,
                intent: intent,
                generation: generation
            )
        }
        guard accepted else {
            lock.lock()
            if state == .pausing(intent), self.generation == generation {
                state = requiresRetryableState ? .retryable(intent) : .idle
                self.observer = nil
            }
            lock.unlock()
            return false
        }
        return true
    }

    private func pauseDidComplete(
        _ paused: Bool,
        intent: HostAgentXPCCommandIntent,
        generation: UInt64
    ) {
        lock.lock()
        guard state == .pausing(intent), self.generation == generation,
              let observer
        else {
            lock.unlock()
            return
        }
        guard paused else {
            state = .invalidated
            self.observer = nil
            lock.unlock()
            observer(.invalidState)
            // A deferred false means the polling owner became terminal while
            // draining its in-flight fetch. Its typed terminal callback owns
            // the session reason and follows this completion.
            return
        }
        state = .awaitingAcceptance(intent)
        lock.unlock()

        client.submitCommand(
            commandID: intent.commandID,
            name: intent.name,
            connectionID: intent.connectionID
        ) { [weak self] result in
            self?.clientDidPublish(
                result,
                intent: intent,
                generation: generation
            )
        }
    }

    private func clientDidPublish(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        intent: HostAgentXPCCommandIntent,
        generation: UInt64
    ) {
        switch result {
        case .accepted:
            acceptQueued(result, intent: intent, generation: generation)
        case .completed:
            finish(
                result,
                nextState: .idle,
                intent: intent,
                generation: generation
            )
        case .resultUnknown, .resultTimedOut:
            finish(
                result,
                nextState: .retryable(intent),
                intent: intent,
                generation: generation
            )
        case .invalidRequest:
            finishBeforeAcceptance(
                result,
                intent: intent,
                generation: generation,
                invalidate: false
            )
        case .invalidResponse, .disconnected, .acceptanceTimedOut,
             .cancelled, .invalidState:
            finishBeforeAcceptance(
                result,
                intent: intent,
                generation: generation,
                invalidate: true
            )
        }
    }

    private func acceptQueued(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        intent: HostAgentXPCCommandIntent,
        generation: UInt64
    ) {
        lock.lock()
        guard state == .awaitingAcceptance(intent),
              self.generation == generation,
              let observer
        else {
            lock.unlock()
            return
        }
        state = .awaitingResult(intent)
        lock.unlock()

        guard polling.resume(
            delayMilliseconds: Self.acceptanceResumeDelayMilliseconds
        ) else {
            invalidateAfterAccepted(
                observer: observer,
                intent: intent,
                generation: generation,
                accepted: result
            )
            return
        }
        observer(result)
    }

    private func invalidateAfterAccepted(
        observer: @escaping Observer,
        intent: HostAgentXPCCommandIntent,
        generation: UInt64,
        accepted: HostAgentXPCSnapshotClientCommandResult
    ) {
        lock.lock()
        guard state == .awaitingResult(intent),
              self.generation == generation
        else {
            lock.unlock()
            return
        }
        state = .invalidated
        self.observer = nil
        lock.unlock()
        observer(accepted)
        observer(.invalidState)
        onInvalidationRequired(.invalidState)
    }

    private func finish(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        nextState: HostAgentXPCCommandIntentOwnerState,
        intent: HostAgentXPCCommandIntent,
        generation: UInt64
    ) {
        lock.lock()
        guard state == .awaitingResult(intent),
              self.generation == generation,
              let observer
        else {
            lock.unlock()
            return
        }
        state = nextState
        self.observer = nil
        lock.unlock()
        observer(result)
    }

    private func finishBeforeAcceptance(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        intent: HostAgentXPCCommandIntent,
        generation: UInt64,
        invalidate: Bool
    ) {
        lock.lock()
        guard state == .awaitingAcceptance(intent),
              self.generation == generation,
              let observer
        else {
            lock.unlock()
            return
        }
        state = invalidate ? .invalidated : .idle
        self.observer = nil
        lock.unlock()

        if !invalidate, !polling.resume(delayMilliseconds: 0) {
            observer(.invalidState)
            onInvalidationRequired(.invalidState)
            return
        }
        observer(result)
        if invalidate { onInvalidationRequired(result) }
    }
}
