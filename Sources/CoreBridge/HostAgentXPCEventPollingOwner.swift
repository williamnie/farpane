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
        guard state == .fetching, self.generation == generation else {
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
        scheduleAfterResult(
            delayMilliseconds: nextDelay,
            generation: generation
        )
    }

    private func scheduleAfterResult(
        delayMilliseconds: UInt64,
        generation: UInt64
    ) {
        lock.lock()
        guard state == .fetching, self.generation == generation else {
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
        lock.unlock()

        scheduledTask?.cancel()
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
