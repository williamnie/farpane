@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCCommandServiceTests: XCTestCase {
    func testMalformedOrForeignRequestNeverReachesPrepare() throws {
        let recorder = CommandServiceRecorder()
        let service = try makeService(recorder: recorder)

        XCTAssertNil(service.prepareResponse(for: Data()))
        XCTAssertNil(service.prepareResponse(for: try makeRequest(
            hostID: "host-b"
        ).encoded()))
        XCTAssertEqual(recorder.preparedExecutions.count, 0)
        XCTAssertEqual(recorder.publishedResults.count, 0)
    }

    func testNewCommandIsMarkedQueuedBeforeOneShotWorkStarts() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        recorder.ticketFactory = { execution in
            HostAgentXPCCommandQueueTicket {
                recorder.recordStarted(
                    execution,
                    queuedCount: authority.snapshot().queuedCount
                )
            }
        }
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let request = try makeRequest()

        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))
        let response = try HostAgentXPCWireCommandAcceptedResponse.decode(
            prepared.data
        )

        XCTAssertEqual(response.evaluate(for: request), .correlated)
        XCTAssertEqual(response.acceptance, .queued)
        XCTAssertTrue(prepared.hasPostReplyAction)
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(recorder.startedExecutions.count, 0)
        XCTAssertEqual(authority.snapshot().queuedCount, 1)
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertEqual(recorder.startedExecutions.count, 1)
        XCTAssertEqual(recorder.queuedCountsAtStart, [1])
    }

    func testPrepareFailureRollsBackReservationForFreshRetry() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        recorder.failPreparationCount = 1
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let request = try makeRequest()

        XCTAssertNil(service.prepareResponse(for: try request.encoded()))
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))
        XCTAssertEqual(recorder.preparedExecutions.count, 2)
        XCTAssertEqual(recorder.startedExecutions.count, 0)
        XCTAssertEqual(authority.snapshot().queuedCount, 1)
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertEqual(recorder.startedExecutions.count, 1)
    }

    func testConcurrentDuplicateWaitsWhileFirstPrepareIsPending() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        let prepareEntered = DispatchSemaphore(value: 0)
        let releasePrepare = DispatchSemaphore(value: 0)
        recorder.ticketFactory = { execution in
            prepareEntered.signal()
            releasePrepare.wait()
            return HostAgentXPCCommandQueueTicket {
                recorder.recordStarted(execution)
            }
        }
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let requestData = try makeRequest().encoded()
        let firstDone = DispatchSemaphore(value: 0)
        let replyLock = NSLock()
        var firstReply: HostAgentXPCCommandPreparedResponse?
        DispatchQueue.global().async {
            let reply = service.prepareResponse(for: requestData)
            replyLock.lock()
            firstReply = reply
            replyLock.unlock()
            firstDone.signal()
        }
        XCTAssertEqual(prepareEntered.wait(timeout: .now() + 2), .success)

        XCTAssertNil(service.prepareResponse(for: requestData))
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        releasePrepare.signal()
        XCTAssertEqual(firstDone.wait(timeout: .now() + 2), .success)
        replyLock.lock()
        let receivedFirstReply = firstReply
        replyLock.unlock()
        let first = try XCTUnwrap(receivedFirstReply)
        XCTAssertEqual(recorder.startedExecutions.count, 0)
        XCTAssertTrue(first.performAfterReply())
        let duplicate = try XCTUnwrap(service.prepareResponse(
            for: requestData
        ))
        XCTAssertFalse(duplicate.hasPostReplyAction)
        XCTAssertTrue(duplicate.performAfterReply())
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(recorder.startedExecutions.count, 1)
    }

    func testFreshRequestReplaysCompletedResultWithoutPreparingAgain()
        throws
    {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let request = try makeRequest()
        _ = try prepareAndPerform(service, request: request)
        let result = try commandResult(commandID: request.commandID)

        XCTAssertEqual(service.acceptResult(result), .published)
        XCTAssertEqual(service.acceptResult(result), .unchanged)
        XCTAssertEqual(recorder.publishedResults, [result])

        let retry = try makeRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676"
        )
        let replay = try XCTUnwrap(service.prepareResponse(
            for: try retry.encoded()
        ))
        XCTAssertEqual(
            try HostAgentXPCWireCommandAcceptedResponse.decode(replay.data)
                .evaluate(for: retry),
            .correlated
        )
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(recorder.startedExecutions.count, 1)
        XCTAssertEqual(recorder.publishedResults, [result])
        XCTAssertTrue(replay.performAfterReply())
        XCTAssertEqual(recorder.publishedResults, [result, result])
    }

    func testPublicationFailureRetainsResultForRequestReplay() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        recorder.failPublicationCount = 1
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let request = try makeRequest()
        _ = try prepareAndPerform(service, request: request)
        let result = try commandResult(commandID: request.commandID)

        XCTAssertEqual(service.acceptResult(result), .retainedForReplay)
        XCTAssertEqual(authority.snapshot().completedCount, 1)
        let retry = try makeRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676"
        )
        let replay = try XCTUnwrap(service.prepareResponse(
            for: try retry.encoded()
        ))
        XCTAssertTrue(replay.performAfterReply())
        XCTAssertEqual(recorder.publicationAttempts, [result, result])
        XCTAssertEqual(recorder.publishedResults, [result])
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
    }

    func testReplayPublicationFailureOccursAfterAcknowledgement() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let request = try makeRequest()
        _ = try prepareAndPerform(service, request: request)
        let result = try commandResult(commandID: request.commandID)
        XCTAssertEqual(service.acceptResult(result), .published)
        recorder.failPublicationCount = 1

        let retry = try makeRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676"
        )
        let replay = try XCTUnwrap(service.prepareResponse(
            for: try retry.encoded()
        ))
        XCTAssertNotNil(try HostAgentXPCWireCommandAcceptedResponse.decode(
            replay.data
        ))
        XCTAssertFalse(replay.performAfterReply())
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(authority.snapshot().completedCount, 1)
    }

    func testInvalidClockRollsBackBeforeWorkAndFreshRetryStartsOnce() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        let clock = CommandServiceClock(values: [0, 2])
        let service = try makeService(
            authority: authority,
            recorder: recorder,
            nowUnixMilliseconds: { clock.now() }
        )
        let request = try makeRequest()

        XCTAssertNil(service.prepareResponse(for: try request.encoded()))
        XCTAssertEqual(recorder.startedExecutions.count, 0)
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))
        XCTAssertEqual(recorder.preparedExecutions.count, 2)
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertEqual(recorder.startedExecutions.count, 1)
    }

    func testConflictingPayloadAndUnknownResultFailClosed() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        _ = try prepareAndPerform(service, request: makeRequest())
        XCTAssertNil(service.prepareResponse(for: try makeRequest(
            name: .rejectIncoming
        ).encoded()))
        XCTAssertEqual(
            service.acceptResult(try commandResult(commandID: "unknown")),
            .unknownCommand
        )
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(recorder.publishedResults.count, 0)
    }

    func testContradictoryResultInvalidatesServiceAuthority() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )
        let request = try makeRequest()
        _ = try prepareAndPerform(service, request: request)
        XCTAssertEqual(
            service.acceptResult(try commandResult(
                commandID: request.commandID,
                status: .ok,
                detail: "completed"
            )),
            .published
        )
        XCTAssertEqual(
            service.acceptResult(try commandResult(
                commandID: request.commandID,
                status: .error,
                detail: "contradiction"
            )),
            .invalidated
        )
        XCTAssertNil(service.prepareResponse(for: try request.encoded()))
        XCTAssertEqual(authority.snapshot().state, .invalidated)
    }

    func testPostReplyActionPerformsExactlyOnceUnderConcurrency() throws {
        let recorder = CommandServiceRecorder()
        let ticket = HostAgentXPCCommandQueueTicket {
            recorder.recordTicketStart()
        }
        let action = try XCTUnwrap(ticket.claimPostReplyAction())
        XCTAssertNil(ticket.claimPostReplyAction())
        let group = DispatchGroup()
        let lock = NSLock()
        var starts: [Bool] = []
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                let started = action.perform()
                lock.lock()
                starts.append(started)
                lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(starts.filter { $0 }.count, 1)
        XCTAssertEqual(starts.filter { !$0 }.count, 31)
        XCTAssertEqual(recorder.ticketStartCount, 1)
    }

    func testPreclaimedTicketInvalidatesInsteadOfAcknowledging() throws {
        let authority = try makeAuthority()
        let recorder = CommandServiceRecorder()
        recorder.ticketFactory = { execution in
            let ticket = HostAgentXPCCommandQueueTicket {
                recorder.recordStarted(execution)
            }
            _ = ticket.claimPostReplyAction()
            return ticket
        }
        let service = try makeService(
            authority: authority,
            recorder: recorder
        )

        XCTAssertNil(service.prepareResponse(
            for: try makeRequest().encoded()
        ))
        XCTAssertEqual(recorder.startedExecutions.count, 0)
        XCTAssertEqual(authority.snapshot().state, .invalidated)
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
    }

    func testSourceHasNoXPCSelectorHostCoreOrExternalState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCCommandService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("@objc"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("rdn_host"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("UserDefaults"))
    }

    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    @discardableResult
    private func prepareAndPerform(
        _ service: HostAgentXPCCommandService,
        request: HostAgentXPCWireCommandRequest
    ) throws -> HostAgentXPCCommandPreparedResponse {
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))
        XCTAssertTrue(prepared.performAfterReply())
        return prepared
    }

    private func makeService(
        authority: HostAgentXPCCommandAdmissionAuthority? = nil,
        recorder: CommandServiceRecorder,
        nowUnixMilliseconds: @escaping HostAgentXPCCommandService.Clock = { 2 }
    ) throws -> HostAgentXPCCommandService {
        let identity = try makeIdentity()
        return HostAgentXPCCommandService(
            identity: identity,
            authority: try authority ?? HostAgentXPCCommandAdmissionAuthority(
                identity: identity
            ),
            prepareExecution: { execution in
                recorder.prepare(execution)
            },
            publishResult: { result in
                recorder.publish(result)
            },
            nowUnixMilliseconds: nowUnixMilliseconds
        )
    }

    private func makeAuthority() throws
        -> HostAgentXPCCommandAdmissionAuthority
    {
        try HostAgentXPCCommandAdmissionAuthority(identity: makeIdentity())
    }

    private func makeIdentity() throws -> HostAgentXPCWireAgentIdentity {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "202608090001",
            hostInstanceID: "host-a",
            agentBootID: bootID
        )
    }

    private func makeRequest(
        requestID: String = "287fd5f2-98b7-4183-ac81-6973cef9a610",
        commandID: String = "command-1",
        hostID: String = "host-a",
        name: HostAgentXPCWireCommandName = .approveIncoming
    ) throws -> HostAgentXPCWireCommandRequest {
        try HostAgentXPCWireCommandRequest(
            requestID: requestID,
            commandID: commandID,
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            name: name,
            connectionID: "\(hostID):connection-1",
            sentAtUnixMilliseconds: 1
        )
    }

    private func commandResult(
        commandID: String,
        status: HostAgentXPCWireCommandResultStatus = .ok,
        detail: String = "completed"
    ) throws -> HostAgentXPCWireCommandResult {
        try HostAgentXPCWireCommandResult(
            commandID: commandID,
            status: status,
            detail: detail
        )
    }
}

private final class CommandServiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    var ticketFactory: (@Sendable (HostAgentXPCCommandExecution)
        -> HostAgentXPCCommandQueueTicket?)?
    var failPreparationCount = 0
    var failPublicationCount = 0
    private(set) var preparedExecutions: [HostAgentXPCCommandExecution] = []
    private(set) var startedExecutions: [HostAgentXPCCommandExecution] = []
    private(set) var queuedCountsAtStart: [Int] = []
    private(set) var publicationAttempts: [HostAgentXPCWireCommandResult] = []
    private(set) var publishedResults: [HostAgentXPCWireCommandResult] = []
    private(set) var ticketStartCount = 0

    func prepare(
        _ execution: HostAgentXPCCommandExecution
    ) -> HostAgentXPCCommandQueueTicket? {
        lock.lock()
        preparedExecutions.append(execution)
        if failPreparationCount > 0 {
            failPreparationCount -= 1
            lock.unlock()
            return nil
        }
        let factory = ticketFactory
        lock.unlock()
        return factory?(execution) ?? HostAgentXPCCommandQueueTicket {
            self.recordStarted(execution)
        }
    }

    func publish(_ result: HostAgentXPCWireCommandResult) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        publicationAttempts.append(result)
        if failPublicationCount > 0 {
            failPublicationCount -= 1
            return false
        }
        publishedResults.append(result)
        return true
    }

    func recordStarted(
        _ execution: HostAgentXPCCommandExecution,
        queuedCount: Int? = nil
    ) {
        lock.lock()
        startedExecutions.append(execution)
        if let queuedCount { queuedCountsAtStart.append(queuedCount) }
        lock.unlock()
    }

    func recordTicketStart() {
        lock.lock()
        ticketStartCount += 1
        lock.unlock()
    }
}

private final class CommandServiceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? 0 : values.removeFirst()
    }
}
