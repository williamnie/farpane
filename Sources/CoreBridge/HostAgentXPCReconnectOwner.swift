import Foundation

package protocol HostAgentBackgroundProjectionSessionAuthority:
    AnyObject,
    Sendable
{
    func beginSession() -> HostAgentBackgroundProjectionSessionBinding
    func currentSessionIsAvailable() -> Bool
}

extension HostAgentBackgroundProjectionAuthority:
    HostAgentBackgroundProjectionSessionAuthority
{
    package func currentSessionIsAvailable() -> Bool {
        if case .available = snapshot().phase { return true }
        return false
    }
}

package protocol HostAgentXPCReconnectSession: AnyObject, Sendable {
    @discardableResult
    func start() -> Bool
    func commandStateSnapshot() -> HostAgentXPCCommandIntentOwnerState
    @discardableResult
    func submitCommand(
        _ intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool
    @discardableResult
    func retryCommand(
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool
    func cancel()
}

extension HostAgentXPCSessionLifecycle: HostAgentXPCReconnectSession {}

package protocol HostAgentXPCReconnectScheduledTask: AnyObject, Sendable {
    func cancel()
}

package enum HostAgentXPCReconnectOwnerFailure: Equatable, Sendable {
    case sessionCreation
    case sessionStartRejected
    case invalidState
    case unexpectedCancellation
    case projectionRejected
}

package enum HostAgentXPCReconnectOwnerState: Equatable, Sendable {
    case idle
    case connecting(attempt: UInt64)
    case active
    case waitingToReconnect(
        attempt: UInt64,
        delayMilliseconds: UInt64,
        reason: HostAgentXPCSessionTerminationReason
    )
    case failed(HostAgentXPCReconnectOwnerFailure)
    case cancelled
}

package struct HostAgentXPCReconnectCommandRoute: Equatable, Sendable {
    package let sessionGeneration: UInt64
    package let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity

    package init(
        sessionGeneration: UInt64,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    ) {
        self.sessionGeneration = sessionGeneration
        self.peerIdentity = peerIdentity
    }
}

package enum HostAgentXPCReconnectCommandAvailability:
    Equatable,
    Sendable
{
    case unavailable
    case available(
        route: HostAgentXPCReconnectCommandRoute,
        state: HostAgentXPCCommandIntentOwnerState
    )
}

/// Owns exactly one App-side XPC session lifecycle and recreates it through a
/// fresh projection epoch after recoverable terminal results. Registration,
/// UI activation and process readiness remain outside this owner.
package final class HostAgentXPCReconnectOwner: @unchecked Sendable {
    package typealias Scheduler = @Sendable (
        _ delayMilliseconds: UInt64,
        _ action: @escaping @Sendable () -> Void
    ) -> HostAgentXPCReconnectScheduledTask
    package typealias JitterSource = @Sendable
        (_ upperBound: UInt64) -> UInt64
    package typealias SessionFactory = @Sendable (
        _ previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        _ sink: HostAgentXPCSessionProjectionSink
    ) throws -> HostAgentXPCReconnectSession

    package static let baseDelayMilliseconds: UInt64 = 250
    package static let maximumDelayMilliseconds: UInt64 = 5_000

    private let lock = NSRecursiveLock()
    private let projectionAuthority:
        HostAgentBackgroundProjectionSessionAuthority
    private let schedule: Scheduler
    private let jitter: JitterSource
    private let makeSession: SessionFactory
    private var state: HostAgentXPCReconnectOwnerState = .idle
    private var ownerGeneration: UInt64 = 0
    private var sessionGeneration: UInt64 = 0
    private var consecutiveFailureCount: UInt64 = 0
    private var session: HostAgentXPCReconnectSession?
    private var commandRoute: HostAgentXPCReconnectCommandRoute?
    private var scheduledTask: HostAgentXPCReconnectScheduledTask?

    package static func makeProduct(
        projectionAuthority: HostAgentBackgroundProjectionAuthority,
        queue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-agent.xpc-reconnect",
            qos: .utility
        )
    ) -> HostAgentXPCReconnectOwner {
        HostAgentXPCReconnectOwner(
            projectionAuthority: projectionAuthority,
            schedule: productScheduler(queue: queue),
            jitter: { upperBound in
                guard upperBound > 0 else { return 0 }
                return UInt64.random(in: 0...upperBound)
            },
            makeSession: { previousPeerIdentity, sink in
                try HostAgentXPCSessionLifecycle.makeProduct(
                    previousPeerIdentity: previousPeerIdentity,
                    sink: sink
                )
            }
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
            return HostAgentXPCReconnectDispatchTask(workItem: workItem)
        }
    }

    package init(
        projectionAuthority:
            HostAgentBackgroundProjectionSessionAuthority,
        schedule: @escaping Scheduler,
        jitter: @escaping JitterSource,
        makeSession: @escaping SessionFactory
    ) {
        self.projectionAuthority = projectionAuthority
        self.schedule = schedule
        self.jitter = jitter
        self.makeSession = makeSession
    }

    deinit {
        cancel()
    }

    package func stateSnapshot() -> HostAgentXPCReconnectOwnerState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    package func commandAvailabilitySnapshot()
        -> HostAgentXPCReconnectCommandAvailability
    {
        lock.lock()
        guard state == .active,
              let session,
              let route = commandRoute,
              route.sessionGeneration == sessionGeneration
        else {
            lock.unlock()
            return .unavailable
        }
        lock.unlock()

        let commandState = session.commandStateSnapshot()
        lock.lock()
        let remainsCurrent = state == .active
            && self.session === session
            && commandRoute == route
            && sessionGeneration == route.sessionGeneration
        lock.unlock()
        guard remainsCurrent else { return .unavailable }
        switch commandState {
        case .invalidated, .cancelled:
            return .unavailable
        case .idle, .pausing, .awaitingAcceptance, .awaitingResult,
             .retryable:
            return .available(route: route, state: commandState)
        }
    }

    @discardableResult
    package func submitCommand(
        route: HostAgentXPCReconnectCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        guard let session = currentCommandSession(route: route) else {
            return false
        }
        return session.submitCommand(intent, observer: observer)
    }

    @discardableResult
    package func retryCommand(
        route: HostAgentXPCReconnectCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        guard let session = currentCommandSession(route: route) else {
            return false
        }
        return session.retryCommand(observer: observer)
    }

    @discardableResult
    package func start() -> Bool {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            return false
        }
        ownerGeneration &+= 1
        sessionGeneration &+= 1
        let ownerGeneration = self.ownerGeneration
        let sessionGeneration = self.sessionGeneration
        state = .connecting(attempt: 0)
        lock.unlock()

        createSession(
            attempt: 0,
            ownerGeneration: ownerGeneration,
            sessionGeneration: sessionGeneration
        )
        return true
    }

    package func cancel() {
        lock.lock()
        switch state {
        case .idle, .connecting, .active, .waitingToReconnect:
            state = .cancelled
        case .failed, .cancelled:
            lock.unlock()
            return
        }
        ownerGeneration &+= 1
        sessionGeneration &+= 1
        let scheduledTask = self.scheduledTask
        let session = self.session
        self.scheduledTask = nil
        self.session = nil
        commandRoute = nil
        lock.unlock()

        scheduledTask?.cancel()
        session?.cancel()
    }

    private func createSession(
        attempt: UInt64,
        ownerGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        lock.lock()
        guard state == .connecting(attempt: attempt),
              self.ownerGeneration == ownerGeneration,
              self.sessionGeneration == sessionGeneration,
              session == nil
        else {
            lock.unlock()
            return
        }
        lock.unlock()

        let binding = projectionAuthority.beginSession()
        let relay = HostAgentXPCReconnectSessionSink(
            projectionSink: binding.sink,
            owner: self,
            sessionGeneration: sessionGeneration
        )
        let session: HostAgentXPCReconnectSession
        do {
            session = try makeSession(
                binding.previousPeerIdentity,
                relay
            )
        } catch {
            failSessionCreation(
                binding: binding,
                ownerGeneration: ownerGeneration,
                sessionGeneration: sessionGeneration
            )
            return
        }

        lock.lock()
        guard state == .connecting(attempt: attempt),
              self.ownerGeneration == ownerGeneration,
              self.sessionGeneration == sessionGeneration,
              self.session == nil
        else {
            lock.unlock()
            session.cancel()
            return
        }
        self.session = session
        lock.unlock()

        guard session.start() else {
            failSessionStart(
                ownerGeneration: ownerGeneration,
                sessionGeneration: sessionGeneration
            )
            return
        }
    }

    private func failSessionCreation(
        binding: HostAgentBackgroundProjectionSessionBinding,
        ownerGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        lock.lock()
        let terminalReason: HostAgentXPCSessionTerminationReason
        if case .connecting = state,
           self.ownerGeneration == ownerGeneration,
           self.sessionGeneration == sessionGeneration
        {
            state = .failed(.sessionCreation)
            self.ownerGeneration &+= 1
            self.sessionGeneration &+= 1
            terminalReason = .invalidState
        } else {
            terminalReason = .cancelled
        }
        lock.unlock()
        binding.sink.sessionDidTerminate(terminalReason)
    }

    private func failSessionStart(
        ownerGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        lock.lock()
        guard case .connecting = state,
              self.ownerGeneration == ownerGeneration,
              self.sessionGeneration == sessionGeneration,
              let session
        else {
            lock.unlock()
            return
        }
        state = .failed(.sessionStartRejected)
        self.ownerGeneration &+= 1
        self.sessionGeneration &+= 1
        self.session = nil
        commandRoute = nil
        lock.unlock()
        session.cancel()
    }

    fileprivate func sessionDidBecomeAvailable(
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        sessionGeneration: UInt64
    ) {
        guard projectionAuthority.currentSessionIsAvailable() else {
            failProjection(sessionGeneration: sessionGeneration)
            return
        }
        lock.lock()
        guard case .connecting = state,
              self.sessionGeneration == sessionGeneration,
              session != nil
        else {
            lock.unlock()
            return
        }
        consecutiveFailureCount = 0
        commandRoute = HostAgentXPCReconnectCommandRoute(
            sessionGeneration: sessionGeneration,
            peerIdentity: peerIdentity
        )
        state = .active
        lock.unlock()
    }

    fileprivate func sessionProjectionDidUpdate(
        sessionGeneration: UInt64
    ) {
        if !projectionAuthority.currentSessionIsAvailable() {
            failProjection(sessionGeneration: sessionGeneration)
        }
    }

    fileprivate func sessionDidTerminate(
        _ reason: HostAgentXPCSessionTerminationReason,
        sessionGeneration: UInt64
    ) {
        lock.lock()
        let isCurrentState: Bool
        switch state {
        case .connecting, .active:
            isCurrentState = true
        case .idle, .waitingToReconnect, .failed, .cancelled:
            isCurrentState = false
        }
        guard isCurrentState,
              self.sessionGeneration == sessionGeneration,
              session != nil
        else {
            lock.unlock()
            return
        }
        session = nil
        commandRoute = nil

        switch reason {
        case .invalidState:
            state = .failed(.invalidState)
            ownerGeneration &+= 1
            self.sessionGeneration &+= 1
            lock.unlock()
        case .cancelled:
            state = .failed(.unexpectedCancellation)
            ownerGeneration &+= 1
            self.sessionGeneration &+= 1
            lock.unlock()
        case .incompatible, .invalidResponse, .disconnected, .timedOut:
            if consecutiveFailureCount < UInt64.max {
                consecutiveFailureCount += 1
            }
            let attempt = consecutiveFailureCount
            let expectedOwnerGeneration = ownerGeneration
            let delay = retryDelayMilliseconds(attempt: attempt)
            let isStillCurrent: Bool
            switch state {
            case .connecting, .active:
                isStillCurrent = true
            case .idle, .waitingToReconnect, .failed, .cancelled:
                isStillCurrent = false
            }
            guard isStillCurrent,
                  ownerGeneration == expectedOwnerGeneration,
                  self.sessionGeneration == sessionGeneration,
                  session == nil
            else {
                lock.unlock()
                return
            }
            ownerGeneration &+= 1
            let ownerGeneration = self.ownerGeneration
            state = .waitingToReconnect(
                attempt: attempt,
                delayMilliseconds: delay,
                reason: reason
            )
            lock.unlock()
            installSchedule(
                delayMilliseconds: delay,
                attempt: attempt,
                reason: reason,
                ownerGeneration: ownerGeneration
            )
        }
    }

    private func failProjection(sessionGeneration: UInt64) {
        lock.lock()
        let canFail: Bool
        switch state {
        case .connecting, .active:
            canFail = true
        case .idle, .waitingToReconnect, .failed, .cancelled:
            canFail = false
        }
        guard canFail,
              self.sessionGeneration == sessionGeneration,
              let session
        else {
            lock.unlock()
            return
        }
        state = .failed(.projectionRejected)
        ownerGeneration &+= 1
        self.sessionGeneration &+= 1
        self.session = nil
        commandRoute = nil
        lock.unlock()
        session.cancel()
    }

    private func installSchedule(
        delayMilliseconds: UInt64,
        attempt: UInt64,
        reason: HostAgentXPCSessionTerminationReason,
        ownerGeneration: UInt64
    ) {
        let task = schedule(delayMilliseconds) { [weak self] in
            self?.scheduledReconnectDidFire(
                attempt: attempt,
                reason: reason,
                ownerGeneration: ownerGeneration
            )
        }

        lock.lock()
        guard state == .waitingToReconnect(
                attempt: attempt,
                delayMilliseconds: delayMilliseconds,
                reason: reason
              ),
              self.ownerGeneration == ownerGeneration,
              scheduledTask == nil
        else {
            lock.unlock()
            task.cancel()
            return
        }
        scheduledTask = task
        lock.unlock()
    }

    private func scheduledReconnectDidFire(
        attempt: UInt64,
        reason: HostAgentXPCSessionTerminationReason,
        ownerGeneration: UInt64
    ) {
        lock.lock()
        guard case .waitingToReconnect(
            attempt: attempt,
            delayMilliseconds: _,
            reason: reason
        ) = state,
            self.ownerGeneration == ownerGeneration
        else {
            lock.unlock()
            return
        }
        scheduledTask = nil
        sessionGeneration &+= 1
        let sessionGeneration = self.sessionGeneration
        state = .connecting(attempt: attempt)
        lock.unlock()

        createSession(
            attempt: attempt,
            ownerGeneration: ownerGeneration,
            sessionGeneration: sessionGeneration
        )
    }

    private func retryDelayMilliseconds(attempt: UInt64) -> UInt64 {
        var nominal = Self.baseDelayMilliseconds
        var remainingDoublings = attempt > 0 ? attempt - 1 : 0
        while remainingDoublings > 0,
              nominal < Self.maximumDelayMilliseconds
        {
            nominal = min(Self.maximumDelayMilliseconds, nominal * 2)
            remainingDoublings -= 1
        }
        let upperBound = nominal / 4
        let boundedJitter = min(jitter(upperBound), upperBound)
        return min(
            Self.maximumDelayMilliseconds,
            nominal + boundedJitter
        )
    }

    private func currentCommandSession(
        route: HostAgentXPCReconnectCommandRoute
    ) -> HostAgentXPCReconnectSession? {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active,
              commandRoute == route,
              sessionGeneration == route.sessionGeneration
        else { return nil }
        return session
    }
}

private final class HostAgentXPCReconnectSessionSink:
    HostAgentXPCSessionProjectionSink,
    @unchecked Sendable
{
    private let projectionSink: HostAgentXPCSessionProjectionSink
    private weak var owner: HostAgentXPCReconnectOwner?
    private let sessionGeneration: UInt64

    init(
        projectionSink: HostAgentXPCSessionProjectionSink,
        owner: HostAgentXPCReconnectOwner,
        sessionGeneration: UInt64
    ) {
        self.projectionSink = projectionSink
        self.owner = owner
        self.sessionGeneration = sessionGeneration
    }

    func resetForIdentityReplacement() {
        projectionSink.resetForIdentityReplacement()
    }

    func publishInitialSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) {
        projectionSink.publishInitialSnapshot(
            snapshot,
            peerIdentity: peerIdentity,
            transition: transition
        )
        owner?.sessionDidBecomeAvailable(
            peerIdentity: peerIdentity,
            sessionGeneration: sessionGeneration
        )
    }

    func publishEvents(_ response: HostAgentXPCWireEventCursorResponse) {
        projectionSink.publishEvents(response)
        owner?.sessionProjectionDidUpdate(
            sessionGeneration: sessionGeneration
        )
    }

    func publishResynchronizedSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    ) {
        projectionSink.publishResynchronizedSnapshot(
            snapshot,
            triggeringResponse: triggeringResponse
        )
        owner?.sessionProjectionDidUpdate(
            sessionGeneration: sessionGeneration
        )
    }

    func sessionDidTerminate(_ reason: HostAgentXPCSessionTerminationReason) {
        projectionSink.sessionDidTerminate(reason)
        owner?.sessionDidTerminate(
            reason,
            sessionGeneration: sessionGeneration
        )
    }
}

private final class HostAgentXPCReconnectDispatchTask:
    HostAgentXPCReconnectScheduledTask,
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
