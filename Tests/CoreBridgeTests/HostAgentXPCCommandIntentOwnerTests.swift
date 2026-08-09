@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCCommandIntentOwnerTests: XCTestCase {
    private let intent = HostAgentXPCCommandIntent(
        commandID: "command-1",
        name: .disconnectSession,
        connectionID: "host-a:connection-1"
    )

    func testPausesBeforeSubmitThenResumesAfterAcceptanceAndCompletes() throws {
        let client = CommandIntentTestClient()
        let polling = CommandIntentTestPollingArbiter()
        let results = CommandIntentTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let owner = makeOwner(client: client, polling: polling)

        XCTAssertTrue(owner.submit(intent) { results.append($0) })
        XCTAssertEqual(polling.pauseCount, 1)
        XCTAssertEqual(client.submissions, [])
        polling.completePause(true)
        XCTAssertEqual(client.submissions, [intent])
        XCTAssertEqual(owner.stateSnapshot(), .awaitingAcceptance(intent))

        let accepted = try queuedAcceptance()
        client.publish(.accepted(accepted))
        XCTAssertEqual(polling.resumeDelays, [
            HostAgentXPCCommandIntentOwner
                .acceptanceResumeDelayMilliseconds,
        ])
        XCTAssertEqual(results.values, [.accepted(accepted)])
        XCTAssertEqual(owner.stateSnapshot(), .awaitingResult(intent))

        let completed = try HostAgentXPCWireCommandResult(
            commandID: intent.commandID,
            status: .ok,
            detail: "completed"
        )
        client.publish(.completed(completed))
        XCTAssertEqual(results.values, [
            .accepted(accepted), .completed(completed),
        ])
        XCTAssertEqual(owner.stateSnapshot(), .idle)
    }

    func testRetryRetainsExactIntentAndCommandID() throws {
        let client = CommandIntentTestClient()
        let polling = CommandIntentTestPollingArbiter()
        let first = CommandIntentTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let retry = CommandIntentTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let owner = makeOwner(client: client, polling: polling)

        XCTAssertTrue(owner.submit(intent) { first.append($0) })
        polling.completePause(true)
        client.publish(.accepted(try queuedAcceptance()))
        client.publish(.resultTimedOut)
        XCTAssertEqual(owner.stateSnapshot(), .retryable(intent))
        XCTAssertFalse(owner.submit(
            HostAgentXPCCommandIntent(
                commandID: "command-2",
                name: .rejectIncoming,
                connectionID: "host-a:connection-2"
            )
        ) { _ in })

        XCTAssertTrue(owner.retry { retry.append($0) })
        polling.completePause(true)
        XCTAssertEqual(client.submissions, [intent, intent])
        client.publish(.accepted(try queuedAcceptance()))
        client.publish(.resultUnknown)

        XCTAssertEqual(retry.values.last, .resultUnknown)
        XCTAssertEqual(owner.stateSnapshot(), .retryable(intent))
        XCTAssertEqual(polling.resumeDelays, [100, 100])
    }

    func testInvalidRequestRestoresPollingWithoutInvalidatingSession() {
        let client = CommandIntentTestClient()
        let polling = CommandIntentTestPollingArbiter()
        let results = CommandIntentTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let invalidations = CommandIntentTestRecorder<String>()
        let owner = HostAgentXPCCommandIntentOwner(
            client: client,
            polling: polling,
            onInvalidationRequired: { _ in
                invalidations.append("invalidated")
            }
        )

        XCTAssertTrue(owner.submit(intent) { results.append($0) })
        polling.completePause(true)
        client.publish(.invalidRequest)

        XCTAssertEqual(results.values, [.invalidRequest])
        XCTAssertEqual(polling.resumeDelays, [0])
        XCTAssertEqual(owner.stateSnapshot(), .idle)
        XCTAssertEqual(invalidations.values, [])
    }

    func testCancelDiscardsIntentAndIgnoresLatePauseOrClientCallbacks() {
        let client = CommandIntentTestClient()
        let polling = CommandIntentTestPollingArbiter()
        let results = CommandIntentTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let owner = makeOwner(client: client, polling: polling)

        XCTAssertTrue(owner.submit(intent) { results.append($0) })
        owner.cancel()
        polling.completePause(true)
        client.publish(.invalidState)

        XCTAssertEqual(results.values, [.cancelled])
        XCTAssertEqual(client.submissions, [])
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertFalse(owner.retry { _ in })
    }

    func testDeferredPauseRejectionLeavesTerminalReasonToPollingOwner() {
        let client = CommandIntentTestClient()
        let polling = CommandIntentTestPollingArbiter()
        let results = CommandIntentTestRecorder<
            HostAgentXPCSnapshotClientCommandResult
        >()
        let invalidations = CommandIntentTestRecorder<String>()
        let owner = HostAgentXPCCommandIntentOwner(
            client: client,
            polling: polling,
            onInvalidationRequired: { _ in
                invalidations.append("invalidated")
            }
        )
        XCTAssertTrue(owner.submit(intent) { results.append($0) })

        polling.completePause(false)

        XCTAssertEqual(results.values, [.invalidState])
        XCTAssertEqual(invalidations.values, [])
        XCTAssertEqual(owner.stateSnapshot(), .invalidated)
    }

    func testResumeContradictionFailsClosedAfterAcceptedNotification() throws {
        let client = CommandIntentTestClient()
        let polling = CommandIntentTestPollingArbiter(resumeResult: false)
        let order = CommandIntentTestRecorder<String>()
        let owner = HostAgentXPCCommandIntentOwner(
            client: client,
            polling: polling,
            onInvalidationRequired: { _ in order.append("invalidated") }
        )
        XCTAssertTrue(owner.submit(intent) { result in
            switch result {
            case .accepted: order.append("accepted")
            case .invalidState: order.append("invalidState")
            default: XCTFail("unexpected result \(result)")
            }
        })
        polling.completePause(true)

        client.publish(.accepted(try queuedAcceptance()))

        XCTAssertEqual(order.values, [
            "accepted", "invalidState", "invalidated",
        ])
        XCTAssertEqual(owner.stateSnapshot(), .invalidated)
    }

    private func makeOwner(
        client: CommandIntentTestClient,
        polling: CommandIntentTestPollingArbiter
    ) -> HostAgentXPCCommandIntentOwner {
        HostAgentXPCCommandIntentOwner(
            client: client,
            polling: polling,
            onInvalidationRequired: { _ in
                XCTFail("unexpected invalidation")
            }
        )
    }

    private func queuedAcceptance() throws
        -> HostAgentXPCWireCommandAcceptedResponse
    {
        let request = try HostAgentXPCWireCommandRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            commandID: intent.commandID,
            wireVersion: 2,
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            name: intent.name,
            connectionID: intent.connectionID,
            sentAtUnixMilliseconds: 10
        )
        return try HostAgentXPCWireCommandAcceptedResponse.makeQueued(
            for: request,
            identity: HostAgentXPCWireAgentIdentity.test(
                agentBuildID: "agent-build",
                hostInstanceID: "host-a",
                agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7"
            ),
            sentAtUnixMilliseconds: 20
        )
    }
}

private final class CommandIntentTestClient:
    HostAgentXPCCommandIntentClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [HostAgentXPCCommandIntent] = []
    private var observers: [HostAgentXPCSnapshotClient.CommandObserver] = []

    var submissions: [HostAgentXPCCommandIntent] {
        locked { storage }
    }

    func submitCommand(
        commandID: String,
        name: HostAgentXPCWireCommandName,
        connectionID: String,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) {
        lock.lock()
        storage.append(HostAgentXPCCommandIntent(
            commandID: commandID,
            name: name,
            connectionID: connectionID
        ))
        observers.append(observer)
        lock.unlock()
    }

    func publish(_ result: HostAgentXPCSnapshotClientCommandResult) {
        let observer = locked { observers.last }
        observer?(result)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CommandIntentTestPollingArbiter:
    HostAgentXPCCommandPollingArbiter,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let resumeResult: Bool
    private var pauses = 0
    private var pauseCompletions: [
        HostAgentXPCEventPollingOwner.PauseCompletion
    ] = []
    private var delays: [UInt64] = []

    init(resumeResult: Bool = true) {
        self.resumeResult = resumeResult
    }

    var pauseCount: Int { locked { pauses } }
    var resumeDelays: [UInt64] { locked { delays } }

    func pause(
        completion: @escaping HostAgentXPCEventPollingOwner.PauseCompletion
    ) -> Bool {
        lock.lock()
        pauses += 1
        pauseCompletions.append(completion)
        lock.unlock()
        return true
    }

    func resume(delayMilliseconds: UInt64) -> Bool {
        lock.lock()
        delays.append(delayMilliseconds)
        lock.unlock()
        return resumeResult
    }

    func completePause(_ result: Bool) {
        let completion: HostAgentXPCEventPollingOwner.PauseCompletion? = locked {
            pauseCompletions.isEmpty ? nil : pauseCompletions.removeFirst()
        }
        completion?(result)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class CommandIntentTestRecorder<Value>: @unchecked Sendable {
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
