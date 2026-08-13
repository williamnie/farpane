@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCCommandProcessOwnerTests: XCTestCase {
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"
    private let sentAt: UInt64 = 1_775_696_400_000

    func testBindsRuntimeThenIdentityAndRejectsIdentityReplacement() throws {
        let invalidations = LockedCounter()
        let owner = try makeOwner(onInvalidation: {
            invalidations.increment()
        })

        XCTAssertEqual(owner.stateSnapshot(), .waitingForRuntime)
        XCTAssertTrue(owner.bindRuntimeSubmission { _ in .awaitingCoreResult })
        XCTAssertEqual(owner.stateSnapshot(), .waitingForIdentity)
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .bound)
        XCTAssertEqual(owner.stateSnapshot(), .active)
        XCTAssertNotNil(owner.commandServiceSnapshot())
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .unchanged)

        XCTAssertEqual(
            owner.bindIdentity(hostInstanceID: "host-b"),
            .rejected(.conflictingHostInstance)
        )
        XCTAssertEqual(owner.stateSnapshot(), .invalidated)
        XCTAssertNil(owner.commandServiceSnapshot())
        XCTAssertEqual(invalidations.value, 1)
        owner.invalidate()
        XCTAssertEqual(invalidations.value, 1)
    }

    func testCommandExecutesOnceAndCoreResultEntersTypedJournal() throws {
        let submissions = SubmissionRecorder()
        let forwarded = EventRecorder()
        let state = try HostAgentEventState()
        let owner = try makeOwner(eventState: state) { event in
            forwarded.append(event)
        }
        XCTAssertTrue(owner.bindRuntimeSubmission { submission in
            submissions.append(submission)
            return .awaitingCoreResult
        })
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .bound)
        let service = try XCTUnwrap(owner.commandServiceSnapshot())
        let request = try commandRequest()
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))

        XCTAssertTrue(submissions.values.isEmpty)
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertTrue(submissions.waitForCount(1))
        XCTAssertEqual(submissions.values.count, 1)

        let resultEvent = try coreCommandResultEvent(commandID: request.commandID)
        XCTAssertEqual(
            owner.consumeCoreEvent(resultEvent),
            .consumed(.published)
        )
        XCTAssertTrue(forwarded.values.isEmpty)
        guard case .commandResult(let result, _) =
                state.snapshot().records.first?.payload
        else { return XCTFail("expected typed command result") }
        XCTAssertEqual(result.commandID, request.commandID)

        let retry = try commandRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676"
        )
        let replay = try XCTUnwrap(service.prepareResponse(
            for: try retry.encoded()
        ))
        XCTAssertTrue(replay.performAfterReply())
        XCTAssertEqual(submissions.values.count, 1)
        XCTAssertEqual(state.snapshot().records.count, 1)
    }

    func testNonCommandForwardsButInvalidCommandResultsFailClosed() throws {
        let invalidations = LockedCounter()
        let forwarded = EventRecorder()
        let owner = try makeOwner(
            onEvent: { event in forwarded.append(event) },
            onInvalidation: { invalidations.increment() }
        )
        XCTAssertTrue(owner.bindRuntimeSubmission { _ in .awaitingCoreResult })
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .bound)

        let ordinary = try coreEvent(eventType: "snapshotChanged", payload: [:])
        XCTAssertEqual(owner.consumeCoreEvent(ordinary), .forwarded)
        XCTAssertEqual(forwarded.values.map(\.eventType), ["snapshotChanged"])

        let malformed = try coreEvent(
            eventType: "commandResult",
            payload: ["commandId": "unknown"]
        )
        XCTAssertEqual(owner.consumeCoreEvent(malformed), .invalidated)
        XCTAssertEqual(owner.stateSnapshot(), .invalidated)
        XCTAssertEqual(invalidations.value, 1)
        XCTAssertEqual(forwarded.values.count, 1)
    }

    func testImmediateFailureUsesSameTypedResultPublisher() throws {
        let state = try HostAgentEventState()
        let owner = try makeOwner(eventState: state)
        XCTAssertTrue(owner.bindRuntimeSubmission { _ in
            .rejected(.coreRejected)
        })
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .bound)
        let service = try XCTUnwrap(owner.commandServiceSnapshot())
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try commandRequest().encoded()
        ))

        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertTrue(waitUntil { state.snapshot().records.count == 1 })
        guard case .commandResult(let result, _) =
                state.snapshot().records.first?.payload
        else { return XCTFail("expected immediate typed result") }
        XCTAssertEqual(result.status, .rejected)
        XCTAssertEqual(result.detail, "core-rejected")
    }

    func testForeignAndUnknownCoreResultsEachInvalidateFreshOwner() throws {
        let foreignInvalidations = LockedCounter()
        let foreignOwner = try makeOwner(onInvalidation: {
            foreignInvalidations.increment()
        })
        XCTAssertTrue(foreignOwner.bindRuntimeSubmission { _ in
            .awaitingCoreResult
        })
        XCTAssertEqual(
            foreignOwner.bindIdentity(hostInstanceID: "host-a"),
            .bound
        )
        let foreign = try coreEvent(
            eventType: "commandResult",
            payload: [
                "commandId": "command-1",
                "status": "ok",
                "detail": "completed",
            ],
            hostInstanceID: "host-b"
        )
        XCTAssertEqual(foreignOwner.consumeCoreEvent(foreign), .invalidated)
        XCTAssertEqual(foreignInvalidations.value, 1)

        let unknownInvalidations = LockedCounter()
        let unknownOwner = try makeOwner(onInvalidation: {
            unknownInvalidations.increment()
        })
        XCTAssertTrue(unknownOwner.bindRuntimeSubmission { _ in
            .awaitingCoreResult
        })
        XCTAssertEqual(
            unknownOwner.bindIdentity(hostInstanceID: "host-a"),
            .bound
        )
        let unknown = try coreCommandResultEvent(commandID: "unknown-command")
        XCTAssertEqual(unknownOwner.consumeCoreEvent(unknown), .invalidated)
        XCTAssertEqual(unknownInvalidations.value, 1)
    }

    func testPasswordCommandResultIsConsumedWithoutInvalidatingXPCIdentity() throws {
        let invalidations = LockedCounter()
        let owner = try makeOwner(onInvalidation: {
            invalidations.increment()
        })
        XCTAssertTrue(owner.bindRuntimeSubmission { _ in
            .awaitingCoreResult
        })
        let requestID = "151db9a9-7dd3-4fea-93af-1b6c10840676"
        XCTAssertTrue(owner.bindPasswordSubmission {
            [weak owner] action, _, commandID in
            XCTAssertEqual(action, .revealTemporaryPassword)
            XCTAssertEqual(commandID, requestID)
            guard let owner else {
                throw HostAgentCoreRuntimeAccessError.notRunning
            }
            XCTAssertEqual(
                owner.consumeCoreEvent(
                    try self.coreCommandResultEvent(commandID: commandID)
                ),
                .consumedPasswordOperation
            )
            return Data("temporary-password".utf8)
        })
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .bound)
        let service = try XCTUnwrap(owner.passwordServiceSnapshot())
        let request = try HostAgentXPCWirePasswordRequest(
            wireVersion: 2,
            requestID: requestID,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            sentAtUnixMilliseconds: sentAt,
            action: .revealTemporaryPassword,
            secretLength: 0
        )
        let replied = expectation(description: "password replied")

        service.perform(requestData: try request.encoded(), secretData: nil) {
            responseData, secretData in
            XCTAssertNotNil(responseData)
            XCTAssertEqual(secretData, Data("temporary-password".utf8))
            replied.fulfill()
        }

        wait(for: [replied], timeout: 2)
        XCTAssertEqual(owner.stateSnapshot(), .active)
        XCTAssertNotNil(owner.commandServiceSnapshot())
        XCTAssertNotNil(owner.passwordServiceSnapshot())
        XCTAssertEqual(invalidations.value, 0)
    }

    func testCancelWaitsForQueuedSubmissionAndCannotReactivate() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let owner = try makeOwner()
        XCTAssertTrue(owner.bindRuntimeSubmission { submission in
            if submission.commandID == "command-1" {
                entered.signal()
                release.wait()
            } else {
                secondEntered.signal()
            }
            return .awaitingCoreResult
        })
        XCTAssertEqual(owner.bindIdentity(hostInstanceID: "host-a"), .bound)
        let service = try XCTUnwrap(owner.commandServiceSnapshot())
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try commandRequest().encoded()
        ))
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let second = try XCTUnwrap(service.prepareResponse(
            for: try commandRequest(
                requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
                commandID: "command-2"
            ).encoded()
        ))
        XCTAssertTrue(second.performAfterReply())

        DispatchQueue.global().async {
            XCTAssertTrue(owner.cancelAndWait(timeout: .now() + 2))
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertNil(owner.commandServiceSnapshot())
        XCTAssertFalse(owner.bindRuntimeSubmission { _ in .awaitingCoreResult })
        XCTAssertEqual(
            owner.bindIdentity(hostInstanceID: "host-a"),
            .rejected(.invalidated)
        )
    }

    private func makeOwner(
        eventState: HostAgentEventState? = nil,
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void = { _ in },
        onInvalidation: @escaping @Sendable () -> Void = {}
    ) throws -> HostAgentXPCCommandProcessOwner {
        try HostAgentXPCCommandProcessOwner(
            agentProcessIdentity: try HostAgentXPCWireAgentProcessIdentity(
                agentBuildID: "202608090001",
                agentBootID: bootID,
                agentProcessID: 4_321,
                agentProcessStartIdentitySHA256:
                    String(repeating: "a", count: 64)
            ),
            eventState: eventState ?? HostAgentEventState(),
            nowUnixMilliseconds: { self.sentAt },
            onNonCommandEvent: onEvent,
            onInvalidationRequired: onInvalidation
        )
    }

    private func commandRequest(
        requestID: String = "287fd5f2-98b7-4183-ac81-6973cef9a610",
        commandID: String = "command-1"
    ) throws -> HostAgentXPCWireCommandRequest {
        try HostAgentXPCWireCommandRequest(
            requestID: requestID,
            commandID: commandID,
            wireVersion: 2,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            name: .disconnectSession,
            connectionID: "host-a:connection-1",
            sentAtUnixMilliseconds: sentAt
        )
    }

    private func coreCommandResultEvent(commandID: String) throws
        -> HostCoreEvent
    {
        try coreEvent(
            eventType: "commandResult",
            payload: [
                "commandId": commandID,
                "status": "ok",
                "detail": "completed",
            ]
        )
    }

    private func coreEvent(
        eventType: String,
        payload: [String: Any],
        hostInstanceID: String = "host-a"
    ) throws -> HostCoreEvent {
        let document: [String: Any] = [
            "schemaVersion": 1,
            "eventId": 1,
            "eventType": eventType,
            "hostInstanceId": hostInstanceID,
            "sentAt": sentAt,
            "payload": payload,
        ]
        return try XCTUnwrap(HostCoreEvent(rawJSON:
            JSONSerialization.data(withJSONObject: document)
        ))
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        return predicate()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class SubmissionRecorder: @unchecked Sendable {
    private let lock = NSCondition()
    private var storage: [HostAgentCoreCommandSubmission] = []
    var values: [HostAgentCoreCommandSubmission] { lock.withLock { storage } }
    func append(_ submission: HostAgentCoreCommandSubmission) {
        lock.lock(); storage.append(submission); lock.broadcast(); lock.unlock()
    }
    func waitForCount(_ count: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(2)
        while storage.count < count, lock.wait(until: deadline) {}
        return storage.count >= count
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostCoreEvent] = []
    var values: [HostCoreEvent] { lock.withLock { storage } }
    func append(_ event: HostCoreEvent) { lock.withLock { storage.append(event) } }
}
