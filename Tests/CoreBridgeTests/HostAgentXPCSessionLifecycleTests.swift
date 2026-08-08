@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCSessionLifecycleTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testPublishesInitialSnapshotBeforeStartingAndForwardingPolling()
        throws
    {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let polling = SessionLifecycleTestPollingOwner(order: order)
        let lifecycle = makeLifecycle(
            client: client,
            sink: sink,
            polling: polling
        )

        XCTAssertTrue(lifecycle.start())
        XCTAssertFalse(lifecycle.start())
        XCTAssertEqual(lifecycle.stateSnapshot(), .starting)
        let ready = try readyResult(lastEventID: 7)
        client.reply(ready)

        XCTAssertEqual(order.values, [
            "clientStart", "initialSnapshot", "pollingStart",
        ])
        XCTAssertEqual(
            lifecycle.stateSnapshot(),
            .polling(try peerIdentity(), lastEventID: 7)
        )
        let events = try upToDateEventResponse(afterEventID: 7)
        polling.emit(.events(events))
        let refreshed = try snapshotResponse(lastEventID: 8)
        polling.emit(.resynchronized(
            snapshot: refreshed,
            triggeringResponse: try gapEventResponse(afterEventID: 7)
        ))

        XCTAssertEqual(sink.initialSnapshots.count, 1)
        XCTAssertEqual(sink.eventResponses, [events])
        XCTAssertEqual(sink.resynchronizedSnapshots, [refreshed])
        XCTAssertEqual(sink.terminations, [])
    }

    func testIdentityReplacementResetPrecedesInitialSnapshotAndPolling()
        throws
    {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let polling = SessionLifecycleTestPollingOwner(order: order)
        let lifecycle = makeLifecycle(
            client: client,
            sink: sink,
            polling: polling
        )
        XCTAssertTrue(lifecycle.start())

        lifecycle.identityReplacementRequired()
        client.reply(try readyResult(
            lastEventID: 1,
            transition: .replacedPrevious
        ))

        XCTAssertEqual(order.values, [
            "clientStart", "identityReset", "initialSnapshot", "pollingStart",
        ])
        XCTAssertEqual(sink.identityResetCount, 1)
    }

    func testInitialFailureTerminatesWithoutConstructingPollingOwner() {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let pollingFactories = SessionLifecycleTestRecorder<String>()
        let lifecycle = HostAgentXPCSessionLifecycle(
            client: client,
            sink: sink,
            makePollingOwner: { _, _ in
                pollingFactories.append("created")
                return SessionLifecycleTestPollingOwner(order: order)
            }
        )
        XCTAssertTrue(lifecycle.start())

        client.reply(.incompatible)
        client.reply(.invalidResponse)

        XCTAssertEqual(pollingFactories.values, [])
        XCTAssertEqual(sink.terminations, [.incompatible])
        XCTAssertEqual(
            lifecycle.stateSnapshot(),
            .failed(.incompatible)
        )
        XCTAssertEqual(client.cancelCount, 1)
    }

    func testPollingStartFailureTearsDownOwnedResources() throws {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let polling = SessionLifecycleTestPollingOwner(
            order: order,
            startResult: false
        )
        let lifecycle = makeLifecycle(
            client: client,
            sink: sink,
            polling: polling
        )
        XCTAssertTrue(lifecycle.start())

        client.reply(try readyResult(lastEventID: 1))

        XCTAssertEqual(order.values, [
            "clientStart", "initialSnapshot", "pollingStart",
            "pollingCancel", "clientCancel", "terminal:invalidState",
        ])
        XCTAssertEqual(sink.terminations, [.invalidState])
        XCTAssertEqual(lifecycle.stateSnapshot(), .failed(.invalidState))
    }

    func testCancelStopsPollingBeforeClientAndIgnoresLateCallbacks() throws {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let polling = SessionLifecycleTestPollingOwner(order: order)
        let lifecycle = makeLifecycle(
            client: client,
            sink: sink,
            polling: polling
        )
        XCTAssertTrue(lifecycle.start())
        client.reply(try readyResult(lastEventID: 1))

        lifecycle.cancel()
        lifecycle.cancel()
        polling.emit(.events(try upToDateEventResponse(afterEventID: 1)))
        client.reply(.disconnected)

        XCTAssertEqual(order.values, [
            "clientStart", "initialSnapshot", "pollingStart",
            "pollingCancel", "clientCancel", "terminal:cancelled",
        ])
        XCTAssertEqual(sink.eventResponses, [])
        XCTAssertEqual(sink.terminations, [.cancelled])
        XCTAssertEqual(lifecycle.stateSnapshot(), .cancelled)
    }

    func testConnectionEndStopsPollingThenClientAndTerminatesOnce() throws {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let polling = SessionLifecycleTestPollingOwner(order: order)
        let lifecycle = makeLifecycle(
            client: client,
            sink: sink,
            polling: polling
        )
        XCTAssertTrue(lifecycle.start())
        client.reply(try readyResult(lastEventID: 1))

        lifecycle.connectionDidEnd()
        lifecycle.connectionDidEnd()
        polling.fail(.timedOut)

        XCTAssertEqual(order.values, [
            "clientStart", "initialSnapshot", "pollingStart",
            "pollingConnectionEnd", "clientCancel", "terminal:disconnected",
        ])
        XCTAssertEqual(sink.terminations, [.disconnected])
        XCTAssertEqual(
            lifecycle.stateSnapshot(),
            .failed(.disconnected)
        )
    }

    func testTerminalProjectionWaitsForAcceptedEventDelivery() throws {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleBlockingSink()
        let polling = SessionLifecycleTestPollingOwner(order: order)
        let lifecycle = HostAgentXPCSessionLifecycle(
            client: client,
            sink: sink,
            makePollingOwner: { onResult, onTerminal in
                polling.bind(onResult: onResult, onTerminal: onTerminal)
                return polling
            }
        )
        XCTAssertTrue(lifecycle.start())
        client.reply(try readyResult(lastEventID: 1))
        let event = try upToDateEventResponse(afterEventID: 1)

        DispatchQueue.global().async {
            polling.emit(.events(event))
        }
        XCTAssertEqual(sink.eventEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            lifecycle.connectionDidEnd()
        }
        XCTAssertEqual(
            sink.terminalDelivered.wait(timeout: .now() + 0.05),
            .timedOut
        )
        sink.releaseEvent.signal()
        XCTAssertEqual(
            sink.terminalDelivered.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(sink.order.values, ["events", "terminal"])
    }

    func testCancelBeforeStartIsTerminalAndSourceOwnsNoUIReadinessOrCommand()
        throws
    {
        let order = SessionLifecycleTestRecorder<String>()
        let client = SessionLifecycleTestClient(order: order)
        let sink = SessionLifecycleTestSink(order: order)
        let polling = SessionLifecycleTestPollingOwner(order: order)
        let lifecycle = makeLifecycle(
            client: client,
            sink: sink,
            polling: polling
        )

        lifecycle.cancel()
        XCTAssertFalse(lifecycle.start())
        XCTAssertEqual(lifecycle.stateSnapshot(), .cancelled)
        XCTAssertEqual(order.values, ["clientCancel", "terminal:cancelled"])

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCSessionLifecycle.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(
            "HostAgentXPCSnapshotClient.makeProduct("
        ))
        XCTAssertTrue(source.contains(
            "HostAgentXPCEventPollingOwner.makeProduct("
        ))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("HostAgentBackgroundComponentHealth"))
        XCTAssertFalse(source.contains("HostAgentXPCWireCommand"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func makeLifecycle(
        client: SessionLifecycleTestClient,
        sink: SessionLifecycleTestSink,
        polling: SessionLifecycleTestPollingOwner
    ) -> HostAgentXPCSessionLifecycle {
        HostAgentXPCSessionLifecycle(
            client: client,
            sink: sink,
            makePollingOwner: { onResult, onTerminal in
                polling.bind(onResult: onResult, onTerminal: onTerminal)
                return polling
            }
        )
    }

    private func readyResult(
        lastEventID: UInt64,
        transition: HostAgentXPCSnapshotClientIdentityTransition =
            .firstObservation
    ) throws -> HostAgentXPCSnapshotClientResult {
        .ready(
            snapshot: try snapshotResponse(lastEventID: lastEventID),
            peerIdentity: try peerIdentity(),
            identityTransition: transition
        )
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

    private func upToDateEventResponse(afterEventID: UInt64) throws
        -> HostAgentXPCWireEventCursorResponse
    {
        let request = try eventRequest(afterEventID: afterEventID)
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: .upToDate(latestSequence: afterEventID),
            sentAtUnixMilliseconds: 22
        )
    }

    private func gapEventResponse(afterEventID: UInt64) throws
        -> HostAgentXPCWireEventCursorResponse
    {
        let request = try eventRequest(afterEventID: afterEventID)
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try identity(),
            replay: .gap(
                firstAvailableSequence: afterEventID + 2,
                latestSequence: afterEventID + 3
            ),
            sentAtUnixMilliseconds: 22
        )
    }

    private func eventRequest(afterEventID: UInt64) throws
        -> HostAgentXPCWireEventCursorRequest
    {
        try HostAgentXPCWireEventCursorRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: afterEventID,
            maximumEventCount: 64,
            sentAtUnixMilliseconds: 12
        )
    }

    private func identity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
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

private final class SessionLifecycleTestClient:
    HostAgentXPCSessionClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let order: SessionLifecycleTestRecorder<String>
    private var completion: (@Sendable
        (HostAgentXPCSnapshotClientResult) -> Void)?
    private var cancels = 0

    init(order: SessionLifecycleTestRecorder<String>) {
        self.order = order
    }

    var cancelCount: Int { locked { cancels } }

    func start(
        completion: @escaping @Sendable
            (HostAgentXPCSnapshotClientResult) -> Void
    ) {
        lock.lock()
        self.completion = completion
        lock.unlock()
        order.append("clientStart")
    }

    func cancel() {
        lock.lock()
        cancels += 1
        lock.unlock()
        order.append("clientCancel")
    }

    func reply(_ result: HostAgentXPCSnapshotClientResult) {
        locked { completion }?(result)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SessionLifecycleTestPollingOwner:
    HostAgentXPCSessionPollingOwner,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let order: SessionLifecycleTestRecorder<String>
    private let startResult: Bool
    private var onResult: (@Sendable
        (HostAgentXPCSnapshotClientEventResult) -> Void)?
    private var onTerminal: (@Sendable
        (HostAgentXPCSnapshotClientEventResult) -> Void)?

    init(
        order: SessionLifecycleTestRecorder<String>,
        startResult: Bool = true
    ) {
        self.order = order
        self.startResult = startResult
    }

    func bind(
        onResult: @escaping @Sendable
            (HostAgentXPCSnapshotClientEventResult) -> Void,
        onTerminal: @escaping @Sendable
            (HostAgentXPCSnapshotClientEventResult) -> Void
    ) {
        lock.lock()
        self.onResult = onResult
        self.onTerminal = onTerminal
        lock.unlock()
    }

    func start() -> Bool {
        order.append("pollingStart")
        return startResult
    }

    func cancel() {
        order.append("pollingCancel")
    }

    func connectionDidEnd() {
        order.append("pollingConnectionEnd")
    }

    func emit(_ result: HostAgentXPCSnapshotClientEventResult) {
        locked { onResult }?(result)
    }

    func fail(_ result: HostAgentXPCSnapshotClientEventResult) {
        locked { onTerminal }?(result)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SessionLifecycleTestSink:
    HostAgentXPCSessionProjectionSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let order: SessionLifecycleTestRecorder<String>
    private(set) var identityResetCount = 0
    private(set) var initialSnapshots: [HostAgentXPCWireSnapshotResponse] = []
    private(set) var eventResponses: [HostAgentXPCWireEventCursorResponse] = []
    private(set) var resynchronizedSnapshots: [
        HostAgentXPCWireSnapshotResponse
    ] = []
    private(set) var terminations: [
        HostAgentXPCSessionTerminationReason
    ] = []

    init(order: SessionLifecycleTestRecorder<String>) {
        self.order = order
    }

    func resetForIdentityReplacement() {
        lock.lock()
        identityResetCount += 1
        lock.unlock()
        order.append("identityReset")
    }

    func publishInitialSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) {
        lock.lock()
        initialSnapshots.append(snapshot)
        lock.unlock()
        order.append("initialSnapshot")
    }

    func publishEvents(_ response: HostAgentXPCWireEventCursorResponse) {
        lock.lock()
        eventResponses.append(response)
        lock.unlock()
        order.append("events")
    }

    func publishResynchronizedSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    ) {
        lock.lock()
        resynchronizedSnapshots.append(snapshot)
        lock.unlock()
        order.append("resynchronizedSnapshot")
    }

    func sessionDidTerminate(_ reason: HostAgentXPCSessionTerminationReason) {
        lock.lock()
        terminations.append(reason)
        lock.unlock()
        order.append("terminal:\(reason)")
    }
}

private final class SessionLifecycleBlockingSink:
    HostAgentXPCSessionProjectionSink,
    @unchecked Sendable
{
    let eventEntered = DispatchSemaphore(value: 0)
    let releaseEvent = DispatchSemaphore(value: 0)
    let terminalDelivered = DispatchSemaphore(value: 0)
    let order = SessionLifecycleTestRecorder<String>()

    func resetForIdentityReplacement() {}

    func publishInitialSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        peerIdentity: HostAgentXPCSnapshotClientPeerIdentity,
        transition: HostAgentXPCSnapshotClientIdentityTransition
    ) {}

    func publishEvents(_ response: HostAgentXPCWireEventCursorResponse) {
        eventEntered.signal()
        releaseEvent.wait()
        order.append("events")
    }

    func publishResynchronizedSnapshot(
        _ snapshot: HostAgentXPCWireSnapshotResponse,
        triggeringResponse: HostAgentXPCWireEventCursorResponse
    ) {}

    func sessionDidTerminate(_ reason: HostAgentXPCSessionTerminationReason) {
        order.append("terminal")
        terminalDelivered.signal()
    }
}

private final class SessionLifecycleTestRecorder<Value>: @unchecked Sendable {
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
