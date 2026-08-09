@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCEventPollingOwnerTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testSeriallyCatchesUpHasMoreThenUsesIdleCadence() throws {
        let client = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let scheduler = EventPollingTestScheduler()
        let results = EventPollingTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let owner = HostAgentXPCEventPollingOwner(
            client: client,
            schedule: scheduler.schedule,
            onResult: { results.append($0) },
            onTerminal: { _ in XCTFail("unexpected terminal result") }
        )

        XCTAssertTrue(owner.start())
        XCTAssertFalse(owner.start())
        XCTAssertEqual(scheduler.pendingDelays, [0])
        scheduler.fireNext()
        XCTAssertEqual(client.fetchCount, 1)
        XCTAssertEqual(owner.stateSnapshot(), .fetching)
        XCTAssertEqual(scheduler.pendingDelays, [])

        let catchUp = try batchResponse(hasMore: true)
        client.reply(.events(catchUp))
        XCTAssertEqual(results.values, [.events(catchUp)])
        XCTAssertEqual(
            scheduler.pendingDelays,
            [HostAgentXPCEventPollingOwner.catchUpDelayMilliseconds]
        )

        scheduler.fireNext()
        XCTAssertEqual(client.fetchCount, 2)
        let idle = try upToDateResponse()
        client.reply(.events(idle))
        XCTAssertEqual(results.values, [.events(catchUp), .events(idle)])
        XCTAssertEqual(
            scheduler.pendingDelays,
            [HostAgentXPCEventPollingOwner.idleDelayMilliseconds]
        )
    }

    func testResynchronizedSnapshotReturnsToCatchUpCadence() throws {
        let client = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let scheduler = EventPollingTestScheduler()
        let results = EventPollingTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let owner = HostAgentXPCEventPollingOwner(
            client: client,
            schedule: scheduler.schedule,
            onResult: { results.append($0) },
            onTerminal: { _ in XCTFail("unexpected terminal result") }
        )
        XCTAssertTrue(owner.start())
        scheduler.fireNext()
        let trigger = try gapResponse()
        let snapshot = try snapshotResponse(lastEventID: 3)

        client.reply(.resynchronized(
            snapshot: snapshot,
            triggeringResponse: trigger
        ))

        XCTAssertEqual(results.values, [.resynchronized(
            snapshot: snapshot,
            triggeringResponse: trigger
        )])
        XCTAssertEqual(
            scheduler.pendingDelays,
            [HostAgentXPCEventPollingOwner.catchUpDelayMilliseconds]
        )
    }

    func testCancelRemovesScheduledWorkAndIgnoresInflightReply() throws {
        let scheduledClient = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let scheduled = EventPollingTestScheduler()
        let scheduledOwner = HostAgentXPCEventPollingOwner(
            client: scheduledClient,
            schedule: scheduled.schedule,
            onResult: { _ in XCTFail("unexpected result") },
            onTerminal: { _ in XCTFail("unexpected terminal result") }
        )
        XCTAssertTrue(scheduledOwner.start())
        scheduledOwner.cancel()
        scheduledOwner.cancel()
        scheduled.fireNext()
        XCTAssertEqual(scheduledClient.fetchCount, 0)
        XCTAssertEqual(scheduledOwner.stateSnapshot(), .cancelled)

        let inflightClient = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let inflight = EventPollingTestScheduler()
        let results = EventPollingTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let inflightOwner = HostAgentXPCEventPollingOwner(
            client: inflightClient,
            schedule: inflight.schedule,
            onResult: { results.append($0) },
            onTerminal: { _ in XCTFail("unexpected terminal result") }
        )
        XCTAssertTrue(inflightOwner.start())
        inflight.fireNext()
        inflightOwner.cancel()
        inflightClient.reply(.events(try upToDateResponse()))
        XCTAssertEqual(results.values, [])
        XCTAssertEqual(inflight.pendingDelays, [])
        XCTAssertEqual(inflightOwner.stateSnapshot(), .cancelled)
    }

    func testConnectionEndAndFetchFailureAreTerminalExactlyOnce() throws {
        let disconnectedClient = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let disconnectedScheduler = EventPollingTestScheduler()
        let disconnected = EventPollingTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let disconnectedOwner = HostAgentXPCEventPollingOwner(
            client: disconnectedClient,
            schedule: disconnectedScheduler.schedule,
            onResult: { _ in XCTFail("unexpected result") },
            onTerminal: { disconnected.append($0) }
        )
        XCTAssertTrue(disconnectedOwner.start())
        disconnectedOwner.connectionDidEnd()
        disconnectedOwner.connectionDidEnd()
        disconnectedScheduler.fireNext()
        XCTAssertEqual(disconnected.values, [.disconnected])
        XCTAssertEqual(disconnectedClient.fetchCount, 0)
        XCTAssertEqual(disconnectedOwner.stateSnapshot(), .failed)

        let failedClient = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let failedScheduler = EventPollingTestScheduler()
        let failed = EventPollingTestRecorder<
            HostAgentXPCSnapshotClientEventResult
        >()
        let failedOwner = HostAgentXPCEventPollingOwner(
            client: failedClient,
            schedule: failedScheduler.schedule,
            onResult: { _ in XCTFail("unexpected result") },
            onTerminal: { failed.append($0) }
        )
        XCTAssertTrue(failedOwner.start())
        failedScheduler.fireNext()
        failedClient.reply(.timedOut)
        failedClient.repeatLastReply(.invalidResponse)
        XCTAssertEqual(failed.values, [.timedOut])
        XCTAssertEqual(failedScheduler.pendingDelays, [])
        XCTAssertEqual(failedOwner.stateSnapshot(), .failed)
    }

    func testStartRequiresReadyClientAndSourceOwnsNoUIOrCommandSurface()
        throws
    {
        let client = EventPollingTestClient(state: .idle)
        let scheduler = EventPollingTestScheduler()
        let owner = HostAgentXPCEventPollingOwner(
            client: client,
            schedule: scheduler.schedule,
            onResult: { _ in },
            onTerminal: { _ in }
        )
        XCTAssertFalse(owner.start())
        XCTAssertEqual(owner.stateSnapshot(), .idle)
        XCTAssertEqual(scheduler.pendingDelays, [])

        let readyClient = EventPollingTestClient(state: .ready(
            try peerIdentity(),
            lastEventID: 0
        ))
        let cancelledOwner = HostAgentXPCEventPollingOwner(
            client: readyClient,
            schedule: scheduler.schedule,
            onResult: { _ in },
            onTerminal: { _ in }
        )
        cancelledOwner.cancel()
        XCTAssertFalse(cancelledOwner.start())
        XCTAssertEqual(cancelledOwner.stateSnapshot(), .cancelled)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCEventPollingOwner.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("HostAgentXPCWireCommand"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    func testProductSchedulerRunsDelayedWorkAndHonorsCancellation() {
        let scheduler = HostAgentXPCEventPollingOwner.productScheduler(
            queue: DispatchQueue(
                label: "io.farpane.tests.xpc-event-poll"
            )
        )
        let fired = expectation(description: "scheduled work fired")
        _ = scheduler(20) { fired.fulfill() }
        wait(for: [fired], timeout: 1)

        let cancelled = expectation(description: "cancelled work did not fire")
        cancelled.isInverted = true
        let task = scheduler(100) { cancelled.fulfill() }
        task.cancel()
        wait(for: [cancelled], timeout: 0.2)
    }

    private func peerIdentity() throws
        -> HostAgentXPCSnapshotClientPeerIdentity
    {
        try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func eventRequest(
        maximumEventCount: Int = 64
    ) throws -> HostAgentXPCWireEventCursorRequest {
        try HostAgentXPCWireEventCursorRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: 0,
            maximumEventCount: maximumEventCount,
            sentAtUnixMilliseconds: 10
        )
    }

    private func batchResponse(hasMore: Bool) throws
        -> HostAgentXPCWireEventCursorResponse
    {
        let state = try HostAgentEventState()
        _ = state.ingestCommandResult(
            try commandResult(id: 1),
            hostInstanceID: hostID,
            sentAtUnixMilliseconds: 1_700_000_000_000
        )
        if hasMore {
            _ = state.ingestCommandResult(
                try commandResult(id: 2),
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: 1_700_000_000_000
            )
        }
        let request = try eventRequest(maximumEventCount: hasMore ? 1 : 64)
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: state.replay(
                afterSequence: 0,
                limit: request.maximumEventCount
            ),
            sentAtUnixMilliseconds: 20
        )
    }

    private func upToDateResponse() throws
        -> HostAgentXPCWireEventCursorResponse
    {
        let request = try eventRequest()
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: HostAgentEventState().replay(afterSequence: 0),
            sentAtUnixMilliseconds: 20
        )
    }

    private func gapResponse() throws
        -> HostAgentXPCWireEventCursorResponse
    {
        let state = try HostAgentEventState(capacity: 2)
        for id in 1...3 {
            _ = state.ingestCommandResult(
                try commandResult(id: UInt64(id)),
                hostInstanceID: hostID,
                sentAtUnixMilliseconds: 1_700_000_000_000
            )
        }
        let request = try eventRequest()
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: state.replay(afterSequence: 0),
            sentAtUnixMilliseconds: 20
        )
    }

    private func snapshotResponse(lastEventID: UInt64) throws
        -> HostAgentXPCWireSnapshotResponse
    {
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(),
            eventSequence: lastEventID,
            expectedHostInstanceID: hostID
        )
        return try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: try identity(),
            state: state.snapshot(),
            sentAtUnixMilliseconds: 21
        )
    }

    private func identity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func commandResult(
        id: UInt64
    ) throws -> HostAgentXPCWireCommandResult {
        try HostAgentXPCWireCommandResult(
            commandID: "command-\(id)",
            status: .ok,
            detail: "completed"
        )
    }

    private func coreSnapshot() throws -> HostCoreSnapshot {
        try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 5,
                "hostInstanceId": hostID,
                "hostState": "ready",
                "localId": "123456789",
                "registrationStatus": "ready",
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

private final class EventPollingTestClient:
    HostAgentXPCEventPollingClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var state: HostAgentXPCSnapshotClientState
    private var completions: [
        @Sendable (HostAgentXPCSnapshotClientEventResult) -> Void
    ] = []
    private var lastCompletion: (@Sendable
        (HostAgentXPCSnapshotClientEventResult) -> Void)?
    private var fetches = 0

    init(state: HostAgentXPCSnapshotClientState) {
        self.state = state
    }

    var fetchCount: Int { locked { fetches } }

    func stateSnapshot() -> HostAgentXPCSnapshotClientState {
        locked { state }
    }

    func fetchEvents(
        completion: @escaping @Sendable
            (HostAgentXPCSnapshotClientEventResult) -> Void
    ) {
        lock.lock()
        fetches += 1
        completions.append(completion)
        lock.unlock()
    }

    func reply(_ result: HostAgentXPCSnapshotClientEventResult) {
        lock.lock()
        let completion = completions.isEmpty
            ? nil : completions.removeFirst()
        lastCompletion = completion
        lock.unlock()
        completion?(result)
    }

    func repeatLastReply(_ result: HostAgentXPCSnapshotClientEventResult) {
        locked { lastCompletion }?(result)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class EventPollingTestScheduler: @unchecked Sendable {
    private struct Pending {
        let delay: UInt64
        let task: EventPollingTestScheduledTask
    }

    private let lock = NSLock()
    private var pending: [Pending] = []

    var pendingDelays: [UInt64] {
        locked { pending.filter { !$0.task.isCancelled }.map(\.delay) }
    }

    lazy var schedule: HostAgentXPCEventPollingOwner.Scheduler = {
        [weak self] delay, action in
        let task = EventPollingTestScheduledTask(action: action)
        self?.lock.lock()
        self?.pending.append(Pending(delay: delay, task: task))
        self?.lock.unlock()
        return task
    }

    func fireNext() {
        let next: Pending? = locked {
            while !pending.isEmpty {
                let candidate = pending.removeFirst()
                if !candidate.task.isCancelled { return candidate }
            }
            return nil
        }
        next?.task.fire()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class EventPollingTestScheduledTask:
    HostAgentXPCEventPollingScheduledTask,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    var isCancelled: Bool { locked { action == nil } }

    func cancel() {
        lock.lock()
        action = nil
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let action = self.action
        self.action = nil
        lock.unlock()
        action?()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class EventPollingTestRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
