@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCReconnectOwnerTests: XCTestCase {
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testStartCreatesExactlyOneSnapshotFirstSession() throws {
        let previousPeer = try peerIdentity()
        let authority = ReconnectTestProjectionAuthority(
            previousPeerIdentity: previousPeer
        )
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )

        XCTAssertTrue(owner.start())
        XCTAssertFalse(owner.start())

        XCTAssertEqual(owner.stateSnapshot(), .connecting(attempt: 0))
        XCTAssertEqual(authority.beginCount, 1)
        XCTAssertEqual(factory.previousPeerIdentities, [previousPeer])
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertEqual(factory.sessions[0].startCount, 1)
        XCTAssertEqual(scheduler.delays, [])
    }

    func testRecoverableTerminalSchedulesSingleCappedBackoffSession() throws {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        XCTAssertTrue(owner.start())
        let first = try XCTUnwrap(factory.sessions.first)

        first.terminate(.disconnected)
        first.terminate(.timedOut)

        XCTAssertEqual(
            owner.stateSnapshot(),
            .waitingToReconnect(
                attempt: 1,
                delayMilliseconds: 250,
                reason: .disconnected
            )
        )
        XCTAssertEqual(scheduler.delays, [250])
        scheduler.tasks[0].fire()
        XCTAssertEqual(owner.stateSnapshot(), .connecting(attempt: 1))
        XCTAssertEqual(factory.sessions.count, 2)
        XCTAssertEqual(authority.beginCount, 2)
    }

    func testBackoffGrowsAndAvailableSnapshotResetsAttempt() throws {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        XCTAssertTrue(owner.start())

        factory.sessions[0].terminate(.disconnected)
        scheduler.tasks[0].fire()
        factory.sessions[1].terminate(.timedOut)
        XCTAssertEqual(scheduler.delays, [250, 500])
        scheduler.tasks[1].fire()
        try factory.sessions[2].publishInitial(
            snapshot: snapshotResponse(lastEventID: 1),
            peerIdentity: peerIdentity(),
            transition: .firstObservation
        )
        XCTAssertEqual(owner.stateSnapshot(), .active)

        factory.sessions[2].terminate(.invalidResponse)

        XCTAssertEqual(scheduler.delays, [250, 500, 250])
        XCTAssertEqual(
            owner.stateSnapshot(),
            .waitingToReconnect(
                attempt: 1,
                delayMilliseconds: 250,
                reason: .invalidResponse
            )
        )
    }

    func testCommandRouteIsBoundToCurrentActiveSessionGeneration() throws {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        XCTAssertTrue(owner.start())
        XCTAssertEqual(owner.commandAvailabilitySnapshot(), .unavailable)
        let firstSession = factory.sessions[0]
        let firstPeer = try peerIdentity()
        try firstSession.publishInitial(
            snapshot: snapshotResponse(lastEventID: 1),
            peerIdentity: firstPeer,
            transition: .firstObservation
        )
        guard case .available(let firstRoute, let commandState) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected command route") }
        XCTAssertEqual(commandState, .idle)
        XCTAssertEqual(firstRoute.sessionGeneration, 1)
        XCTAssertEqual(firstRoute.peerIdentity, firstPeer)
        let intent = HostAgentXPCCommandIntent(
            commandID: "command-1",
            name: .disconnectSession,
            connectionID: "host-a:connection-1"
        )
        XCTAssertTrue(owner.submitCommand(
            route: firstRoute,
            intent: intent,
            observer: { _ in }
        ))
        XCTAssertEqual(firstSession.submittedCommands, [intent])

        firstSession.terminate(.disconnected)
        XCTAssertEqual(owner.commandAvailabilitySnapshot(), .unavailable)
        XCTAssertFalse(owner.submitCommand(
            route: firstRoute,
            intent: intent,
            observer: { _ in }
        ))
        scheduler.tasks[0].fire()
        let secondSession = factory.sessions[1]
        try secondSession.publishInitial(
            snapshot: snapshotResponse(lastEventID: 2),
            peerIdentity: firstPeer,
            transition: .firstObservation
        )
        guard case .available(let secondRoute, _) =
            owner.commandAvailabilitySnapshot()
        else { return XCTFail("expected replacement command route") }
        XCTAssertEqual(secondRoute.sessionGeneration, 2)
        XCTAssertNotEqual(secondRoute, firstRoute)
        XCTAssertFalse(owner.retryCommand(
            route: firstRoute,
            observer: { _ in }
        ))
        XCTAssertTrue(owner.retryCommand(
            route: secondRoute,
            observer: { _ in }
        ))
        XCTAssertEqual(secondSession.retryCount, 1)
    }

    func testBackoffAndJitterNeverExceedProductMaximum() {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = HostAgentXPCReconnectOwner(
            projectionAuthority: authority,
            schedule: { delay, action in
                scheduler.schedule(
                    delayMilliseconds: delay,
                    action: action
                )
            },
            jitter: { upperBound in upperBound },
            makeSession: { previousPeerIdentity, sink in
                try factory.makeSession(
                    previousPeerIdentity: previousPeerIdentity,
                    sink: sink
                )
            }
        )
        XCTAssertTrue(owner.start())

        for index in 0..<8 {
            factory.sessions[index].terminate(.disconnected)
            scheduler.tasks[index].fire()
        }

        XCTAssertEqual(scheduler.delays, [
            312, 625, 1_250, 2_500, 5_000, 5_000, 5_000, 5_000,
        ])
        XCTAssertTrue(scheduler.delays.allSatisfy {
            $0 <= HostAgentXPCReconnectOwner.maximumDelayMilliseconds
        })
    }

    func testCancellationDuringJitterCannotBeOverwrittenByRetryState() {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let ownerBox = ReconnectTestOwnerBox()
        let owner = HostAgentXPCReconnectOwner(
            projectionAuthority: authority,
            schedule: { delay, action in
                scheduler.schedule(
                    delayMilliseconds: delay,
                    action: action
                )
            },
            jitter: { _ in
                ownerBox.cancel()
                return 0
            },
            makeSession: { previousPeerIdentity, sink in
                try factory.makeSession(
                    previousPeerIdentity: previousPeerIdentity,
                    sink: sink
                )
            }
        )
        ownerBox.owner = owner
        XCTAssertTrue(owner.start())

        factory.sessions[0].terminate(.disconnected)

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(scheduler.delays, [])
    }

    func testCancelScheduledRetryPreventsLateTaskFromCreatingSession() {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        XCTAssertTrue(owner.start())
        factory.sessions[0].terminate(.disconnected)

        owner.cancel()
        scheduler.tasks[0].fireIgnoringCancellation()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(scheduler.tasks[0].cancelCount, 1)
        XCTAssertEqual(factory.sessions.count, 1)
        XCTAssertFalse(owner.start())
    }

    func testCancelActiveSessionCannotScheduleReconnectFromTerminalCallback() {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        XCTAssertTrue(owner.start())
        let session = factory.sessions[0]

        owner.cancel()

        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(scheduler.delays, [])
        XCTAssertEqual(authority.terminalReasons, [.cancelled])
    }

    func testCancelDuringThrowingFactoryClosesProjectionEpoch() {
        let authority = ReconnectTestProjectionAuthority()
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        factory.shouldThrow = true
        factory.shouldBlock = true
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        let startFinished = expectation(description: "start returned")
        DispatchQueue.global().async {
            _ = owner.start()
            startFinished.fulfill()
        }
        XCTAssertEqual(
            factory.factoryEntered.wait(timeout: .now() + 2),
            .success
        )

        owner.cancel()
        factory.releaseFactory.signal()
        wait(for: [startFinished], timeout: 2)

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertEqual(authority.terminalReasons, [.cancelled])
        XCTAssertEqual(scheduler.delays, [])
    }

    func testLocalCompositionFailuresStopWithoutRetry() {
        let scheduler = ReconnectTestScheduler()

        let throwingFactory = ReconnectTestSessionFactory()
        throwingFactory.shouldThrow = true
        let creationOwner = makeOwner(
            authority: ReconnectTestProjectionAuthority(),
            scheduler: scheduler,
            factory: throwingFactory
        )
        XCTAssertTrue(creationOwner.start())
        XCTAssertEqual(
            creationOwner.stateSnapshot(),
            .failed(.sessionCreation)
        )

        let rejectingFactory = ReconnectTestSessionFactory()
        rejectingFactory.startResult = false
        let startOwner = makeOwner(
            authority: ReconnectTestProjectionAuthority(),
            scheduler: scheduler,
            factory: rejectingFactory
        )
        XCTAssertTrue(startOwner.start())
        XCTAssertEqual(
            startOwner.stateSnapshot(),
            .failed(.sessionStartRejected)
        )

        let invalidFactory = ReconnectTestSessionFactory()
        let invalidOwner = makeOwner(
            authority: ReconnectTestProjectionAuthority(),
            scheduler: scheduler,
            factory: invalidFactory
        )
        XCTAssertTrue(invalidOwner.start())
        invalidFactory.sessions[0].terminate(.invalidState)
        XCTAssertEqual(
            invalidOwner.stateSnapshot(),
            .failed(.invalidState)
        )
        XCTAssertEqual(scheduler.delays, [])
    }

    func testRejectedProjectionCancelsSessionAndStopsReconnect() throws {
        let authority = ReconnectTestProjectionAuthority()
        authority.acceptInitial = false
        let scheduler = ReconnectTestScheduler()
        let factory = ReconnectTestSessionFactory()
        let owner = makeOwner(
            authority: authority,
            scheduler: scheduler,
            factory: factory
        )
        XCTAssertTrue(owner.start())
        let session = factory.sessions[0]

        try session.publishInitial(
            snapshot: snapshotResponse(lastEventID: 1),
            peerIdentity: peerIdentity(),
            transition: .firstObservation
        )

        XCTAssertEqual(owner.stateSnapshot(), .failed(.projectionRejected))
        XCTAssertEqual(session.cancelCount, 1)
        XCTAssertEqual(scheduler.delays, [])
    }

    func testProductSchedulerExecutesAndCancelsDispatchWork() {
        let queue = DispatchQueue(
            label: "HostAgentXPCReconnectOwnerTests.scheduler"
        )
        let scheduler = HostAgentXPCReconnectOwner.productScheduler(
            queue: queue
        )
        let executed = expectation(description: "scheduled reconnect")
        _ = scheduler(10) { executed.fulfill() }
        wait(for: [executed], timeout: 1)

        let cancelled = expectation(description: "cancelled reconnect")
        cancelled.isInverted = true
        let task = scheduler(50) { cancelled.fulfill() }
        task.cancel()
        wait(for: [cancelled], timeout: 0.15)
    }

    func testProductFactoryIsInertUntilExplicitStart() {
        let authority = HostAgentBackgroundProjectionAuthority()
        let owner = HostAgentXPCReconnectOwner.makeProduct(
            projectionAuthority: authority
        )

        XCTAssertEqual(owner.stateSnapshot(), .idle)
        XCTAssertEqual(authority.snapshot().phase, .idle)
    }

    func testSourceUsesProductCompositionWithoutUIRegistrationOrCommands()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCReconnectOwner.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "HostAgentXPCSessionLifecycle.makeProduct("
        ))
        XCTAssertTrue(source.contains("projectionAuthority.beginSession()"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("HostAgentBackgroundServiceObserver"))
        XCTAssertFalse(source.contains("HostAgentXPCWireCommandRequest"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func makeOwner(
        authority: ReconnectTestProjectionAuthority,
        scheduler: ReconnectTestScheduler,
        factory: ReconnectTestSessionFactory
    ) -> HostAgentXPCReconnectOwner {
        HostAgentXPCReconnectOwner(
            projectionAuthority: authority,
            schedule: { delay, action in
                scheduler.schedule(
                    delayMilliseconds: delay,
                    action: action
                )
            },
            jitter: { _ in 0 },
            makeSession: { previousPeerIdentity, sink in
                try factory.makeSession(
                    previousPeerIdentity: previousPeerIdentity,
                    sink: sink
                )
            }
        )
    }

    private func peerIdentity() throws
        -> HostAgentXPCSnapshotClientPeerIdentity
    {
        try HostAgentXPCSnapshotClientPeerIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: "host-a",
            agentBootID: bootID
        )
    }

    private func snapshotResponse(lastEventID: UInt64) throws
        -> HostAgentXPCWireSnapshotResponse
    {
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 2,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(),
            eventSequence: lastEventID,
            expectedHostInstanceID: "host-a"
        )
        return try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: try HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: "host-a",
                agentBootID: bootID
            ),
            state: state.snapshot(),
            sentAtUnixMilliseconds: 21
        )
    }

    private func coreSnapshot() throws -> HostCoreSnapshot {
        try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8,
                "hostInstanceId": "host-a",
                "hostState": "ready",
                "localId": "123456789",
                "authenticatedConnectionCount": 1,
                "sessionAvailability": "available",
                "sessionUnavailableReason": NSNull(),
                "registrationStatus": "ready",
                "recoveryEpoch": 0,
                "recoveryStatus": "running",
                "pendingApproval": NSNull(),
                "activeSession": NSNull(),
                "temporaryPasswordPresentation": ["policy": "redacted"],
                "passwordPolicy": [
                    "localPasswordSet": true,
                    "effectivePasswordSet": true,
                    "usingPresetPassword": false,
                    "changeAllowed": true,
                    "strengthPolicy": [
                        "version": 1,
                        "minimumCharacters": 6,
                        "maximumCharacters": 128,
                        "maximumUtf8Bytes": 512,
                        "rejectsControlCharacters": true,
                        "rejectsOuterWhitespace": true,
                    ],
                ],
                "lastError": NSNull(),
                "observedAt": 15,
            ]
        ))
    }
}

private final class ReconnectTestProjectionAuthority:
    HostAgentBackgroundProjectionSessionAuthority,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let previousPeerIdentity:
        HostAgentXPCSnapshotClientPeerIdentity?
    private var epoch: UInt64 = 0
    private var begins = 0
    private var currentAvailable = false
    private var terminals: [HostAgentXPCSessionTerminationReason] = []
    var acceptInitial = true

    init(
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity? = nil
    ) {
        self.previousPeerIdentity = previousPeerIdentity
    }

    var beginCount: Int { locked { begins } }
    var terminalReasons: [HostAgentXPCSessionTerminationReason] {
        locked { terminals }
    }

    func beginSession() -> HostAgentBackgroundProjectionSessionBinding {
        lock.lock()
        epoch += 1
        let epoch = self.epoch
        begins += 1
        currentAvailable = false
        lock.unlock()
        return HostAgentBackgroundProjectionSessionBinding(
            previousPeerIdentity: previousPeerIdentity,
            sink: ReconnectTestProjectionSink(
                authority: self,
                epoch: epoch
            )
        )
    }

    func currentSessionIsAvailable() -> Bool {
        locked { currentAvailable }
    }

    func publishInitial(epoch: UInt64) {
        lock.lock()
        if self.epoch == epoch { currentAvailable = acceptInitial }
        lock.unlock()
    }

    func terminate(_ reason: HostAgentXPCSessionTerminationReason, epoch: UInt64) {
        lock.lock()
        if self.epoch == epoch {
            currentAvailable = false
            terminals.append(reason)
        }
        lock.unlock()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ReconnectTestProjectionSink:
    HostAgentXPCSessionProjectionSink,
    @unchecked Sendable
{
    private let authority: ReconnectTestProjectionAuthority
    private let epoch: UInt64

    init(authority: ReconnectTestProjectionAuthority, epoch: UInt64) {
        self.authority = authority
        self.epoch = epoch
    }

    func resetForIdentityReplacement() {}

    func publishInitialSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) {
        authority.publishInitial(epoch: epoch)
    }

    func publishEvents(_ response: HostAgentXPCWireEventCursorResponse) {}

    func publishResynchronizedSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    ) {}

    func sessionDidTerminate(_ reason: HostAgentXPCSessionTerminationReason) {
        authority.terminate(reason, epoch: epoch)
    }
}

private final class ReconnectTestSessionFactory: @unchecked Sendable {
    enum FactoryError: Error { case failed }

    private let lock = NSLock()
    private var storedSessions: [ReconnectTestSession] = []
    private var storedPreviousIdentities: [
        HostAgentXPCSnapshotClientPeerIdentity?
    ] = []
    var shouldThrow = false
    var startResult = true
    var shouldBlock = false
    let factoryEntered = DispatchSemaphore(value: 0)
    let releaseFactory = DispatchSemaphore(value: 0)

    var sessions: [ReconnectTestSession] { locked { storedSessions } }
    var previousPeerIdentities: [HostAgentXPCSnapshotClientPeerIdentity?] {
        locked { storedPreviousIdentities }
    }

    func makeSession(
        previousPeerIdentity: HostAgentXPCSnapshotClientPeerIdentity?,
        sink: HostAgentXPCSessionProjectionSink
    ) throws -> HostAgentXPCReconnectSession {
        lock.lock()
        let shouldBlock = self.shouldBlock
        let shouldThrow = self.shouldThrow
        let startResult = self.startResult
        lock.unlock()
        if shouldBlock {
            factoryEntered.signal()
            releaseFactory.wait()
        }
        if shouldThrow { throw FactoryError.failed }

        lock.lock()
        defer { lock.unlock() }
        let session = ReconnectTestSession(
            sink: sink,
            startResult: startResult
        )
        storedPreviousIdentities.append(previousPeerIdentity)
        storedSessions.append(session)
        return session
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ReconnectTestSession:
    HostAgentXPCReconnectSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let sink: HostAgentXPCSessionProjectionSink
    private let startResult: Bool
    private var starts = 0
    private var cancels = 0
    private var commandState: HostAgentXPCCommandIntentOwnerState = .idle
    private var commands: [HostAgentXPCCommandIntent] = []
    private var retries = 0

    init(sink: HostAgentXPCSessionProjectionSink, startResult: Bool) {
        self.sink = sink
        self.startResult = startResult
    }

    var startCount: Int { locked { starts } }
    var cancelCount: Int { locked { cancels } }
    var submittedCommands: [HostAgentXPCCommandIntent] { locked { commands } }
    var retryCount: Int { locked { retries } }

    func start() -> Bool {
        lock.lock()
        starts += 1
        lock.unlock()
        return startResult
    }

    func commandStateSnapshot() -> HostAgentXPCCommandIntentOwnerState {
        locked { commandState }
    }

    func submitCommand(
        _ intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        lock.lock()
        guard commandState == .idle else {
            lock.unlock()
            return false
        }
        commands.append(intent)
        commandState = .pausing(intent)
        lock.unlock()
        return true
    }

    func retryCommand(
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        lock.lock()
        retries += 1
        lock.unlock()
        return true
    }

    func cancel() {
        lock.lock()
        cancels += 1
        commandState = .cancelled
        lock.unlock()
        sink.sessionDidTerminate(.cancelled)
    }

    func terminate(_ reason: HostAgentXPCSessionTerminationReason) {
        sink.sessionDidTerminate(reason)
    }

    func publishInitial(
        snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) throws {
        sink.publishInitialSnapshot(
            snapshot,
            peerIdentity: peerIdentity,
            transition: transition
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ReconnectTestScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDelays: [UInt64] = []
    private var storedTasks: [ReconnectTestScheduledTask] = []

    var delays: [UInt64] { locked { storedDelays } }
    var tasks: [ReconnectTestScheduledTask] { locked { storedTasks } }

    func schedule(
        delayMilliseconds: UInt64,
        action: @escaping @Sendable () -> Void
    ) -> HostAgentXPCReconnectScheduledTask {
        let task = ReconnectTestScheduledTask(action: action)
        lock.lock()
        storedDelays.append(delayMilliseconds)
        storedTasks.append(task)
        lock.unlock()
        return task
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ReconnectTestScheduledTask:
    HostAgentXPCReconnectScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let action: @Sendable () -> Void
    private var cancelled = false
    private var cancels = 0

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancels
    }

    func cancel() {
        lock.lock()
        cancelled = true
        cancels += 1
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let shouldFire = !cancelled
        lock.unlock()
        if shouldFire { action() }
    }

    func fireIgnoringCancellation() {
        action()
    }
}

private final class ReconnectTestOwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var storage: HostAgentXPCReconnectOwner?

    var owner: HostAgentXPCReconnectOwner? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }

    func cancel() {
        owner?.cancel()
    }
}
