import Foundation

package protocol HostAgentXPCEventPollingClient: AnyObject, Sendable {
    func stateSnapshot() -> HostAgentXPCSnapshotClientState
    func fetchEvents(
        completion: @escaping @Sendable
            (HostAgentXPCSnapshotClientEventResult) -> Void
    )
}

extension HostAgentXPCSnapshotClient: HostAgentXPCEventPollingClient {}

package protocol HostAgentXPCEventPollingScheduledTask:
    AnyObject,
    Sendable
{
    func cancel()
}

package enum HostAgentXPCEventPollingOwnerState: Equatable, Sendable {
    case idle
    case scheduled
    case fetching
    case pausing
    case paused
    case failed
    case cancelled
}

/// Single-start App-side event polling authority. It serializes one bounded
/// client fetch at a time and owns every delayed retry until terminal cancel.
package final class HostAgentXPCEventPollingOwner: @unchecked Sendable {
    package typealias Scheduler = @Sendable (
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> HostAgentXPCEventPollingScheduledTask
    package typealias ResultObserver = @Sendable
        (HostAgentXPCSnapshotClientEventResult) -> Void
    package typealias PauseCompletion = @Sendable (Bool) -> Void

    package static let catchUpDelayMilliseconds: UInt64 = 100
    package static let idleDelayMilliseconds: UInt64 = 500

    private let lock = NSLock()
    private let client: HostAgentXPCEventPollingClient
    private let schedule: Scheduler
    private let onResult: ResultObserver
    private let onTerminal: ResultObserver
    private var state: HostAgentXPCEventPollingOwnerState = .idle
    private var generation: UInt64 = 0
    private var scheduledTask: HostAgentXPCEventPollingScheduledTask?
    private var pauseCompletion: PauseCompletion?

    package static func makeProduct(
        client: HostAgentXPCSnapshotClient,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.xpc-event-poll",
            qos: .utility
        ),
        onResult: @escaping ResultObserver,
        onTerminal: @escaping ResultObserver
    ) -> HostAgentXPCEventPollingOwner {
        HostAgentXPCEventPollingOwner(
            client: client,
            schedule: productScheduler(queue: queue),
            onResult: onResult,
            onTerminal: onTerminal
        )
    }

    package static func productScheduler(
        queue: DispatchQueue
    ) -> Scheduler {
        { delayMilliseconds, action in
            let workItem = DispatchWorkItem(block: action)
            queue.asyncAfter(
                deadline: .now() + .milliseconds(Int(delayMilliseconds)),
                execute: workItem
            )
            return HostAgentXPCEventPollingDispatchTask(
                workItem: workItem
            )
        }
    }

    package init(
        client: HostAgentXPCEventPollingClient,
        schedule: @escaping Scheduler,
        onResult: @escaping ResultObserver,
        onTerminal: @escaping ResultObserver
    ) {
        self.client = client
        self.schedule = schedule
        self.onResult = onResult
        self.onTerminal = onTerminal
    }

    deinit {
        cancel()
    }

    package func stateSnapshot() -> HostAgentXPCEventPollingOwnerState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    @discardableResult
    package func start() -> Bool {
        guard case .ready = client.stateSnapshot() else { return false }

        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return false
        }
        generation &+= 1
        let generation = self.generation
        state = .scheduled
        lock.unlock()

        installSchedule(delayMilliseconds: 0, generation: generation)
        return true
    }

    package func cancel() {
        terminate(state: .cancelled, terminalResult: nil)
    }

    package func connectionDidEnd() {
        terminate(state: .failed, terminalResult: .disconnected)
    }

    /// Stops scheduling new event selectors. If a fetch is already in flight,
    /// its accepted result is delivered first and the completion runs only
    /// after the client has returned to ready.
    @discardableResult
    package func pause(
        completion: @escaping PauseCompletion
    ) -> Bool {
        lock.lock()
        switch state {
        case .scheduled:
            state = .paused
            generation &+= 1
            let scheduledTask = self.scheduledTask
            self.scheduledTask = nil
            lock.unlock()
            scheduledTask?.cancel()
            completion(true)
            return true
        case .fetching:
            state = .pausing
            pauseCompletion = completion
            lock.unlock()
            return true
        case .idle, .pausing, .paused, .failed, .cancelled:
            lock.unlock()
            return false
        }
    }

    /// Resumes only from an acknowledged pause. The caller owns the delay so
    /// command acceptance can leave a bounded post-reply settling window.
    @discardableResult
    package func resume(delayMilliseconds: UInt64) -> Bool {
        guard case .ready = client.stateSnapshot() else { return false }

        lock.lock()
        guard state == .paused else {
            lock.unlock()
            return false
        }
        generation &+= 1
        let generation = self.generation
        state = .scheduled
        lock.unlock()

        installSchedule(
            delayMilliseconds: delayMilliseconds,
            generation: generation
        )
        return true
    }

    private func installSchedule(
        delayMilliseconds: UInt64,
        generation: UInt64
    ) {
        let task = schedule(delayMilliseconds) { [weak self] in
            self?.scheduledFetchDidFire(generation: generation)
        }

        lock.lock()
        guard state == .scheduled,
              self.generation == generation,
              scheduledTask == nil
        else {
            lock.unlock()
            task.cancel()
            return
        }
        scheduledTask = task
        lock.unlock()
    }

    private func scheduledFetchDidFire(generation: UInt64) {
        lock.lock()
        guard state == .scheduled, self.generation == generation else {
            lock.unlock()
            return
        }
        scheduledTask = nil
        state = .fetching
        lock.unlock()

        client.fetchEvents { [weak self] result in
            self?.fetchDidComplete(result, generation: generation)
        }
    }

    private func fetchDidComplete(
        _ result: HostAgentXPCSnapshotClientEventResult,
        generation: UInt64
    ) {
        lock.lock()
        let isCompletable = state == .fetching || state == .pausing
        guard isCompletable, self.generation == generation else {
            lock.unlock()
            return
        }
        lock.unlock()

        let nextDelay: UInt64
        switch result {
        case .events(let response):
            switch response.outcome {
            case .upToDate:
                nextDelay = Self.idleDelayMilliseconds
            case .batch:
                nextDelay = response.hasMore
                    ? Self.catchUpDelayMilliseconds
                    : Self.idleDelayMilliseconds
            case .gap, .invalidCursor, .resnapshotRequired:
                terminate(
                    state: .failed,
                    terminalResult: .invalidResponse,
                    expectedGeneration: generation
                )
                return
            }
        case .resynchronized:
            nextDelay = Self.catchUpDelayMilliseconds
        case .invalidResponse, .disconnected, .timedOut, .cancelled,
             .invalidState:
            terminate(
                state: .failed,
                terminalResult: result,
                expectedGeneration: generation
            )
            return
        }

        onResult(result)
        finishSuccessfulFetch(
            delayMilliseconds: nextDelay,
            generation: generation
        )
    }

    private func finishSuccessfulFetch(
        delayMilliseconds: UInt64,
        generation: UInt64
    ) {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return
        }
        if state == .pausing {
            state = .paused
            let completion = pauseCompletion
            pauseCompletion = nil
            lock.unlock()
            completion?(true)
            return
        }
        guard state == .fetching else {
            lock.unlock()
            return
        }
        state = .scheduled
        lock.unlock()
        installSchedule(
            delayMilliseconds: delayMilliseconds,
            generation: generation
        )
    }

    private func terminate(
        state terminalState: HostAgentXPCEventPollingOwnerState,
        terminalResult: HostAgentXPCSnapshotClientEventResult?,
        expectedGeneration: UInt64? = nil
    ) {
        lock.lock()
        let isTerminable = state == .idle
            || state == .scheduled
            || state == .fetching
            || state == .pausing
            || state == .paused
        guard isTerminable,
              expectedGeneration == nil
                || expectedGeneration == generation
        else {
            lock.unlock()
            return
        }
        state = terminalState
        generation &+= 1
        let scheduledTask = self.scheduledTask
        self.scheduledTask = nil
        let pauseCompletion = self.pauseCompletion
        self.pauseCompletion = nil
        lock.unlock()

        scheduledTask?.cancel()
        pauseCompletion?(false)
        if let terminalResult { onTerminal(terminalResult) }
    }
}

private final class HostAgentXPCEventPollingDispatchTask:
    HostAgentXPCEventPollingScheduledTask,
    @unchecked Sendable
{
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}
