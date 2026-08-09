@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCCommandExecutionAdapterTests: XCTestCase {
    func testSixWireCommandsMapToExactTypedCoreSubmissions() throws {
        let recorder = CommandExecutionAdapterRecorder()
        let adapter = makeAdapter(recorder: recorder)
        let service = try makeService(adapter: adapter)
        let cases: [(HostAgentXPCWireCommandName, HostAgentCoreCommandAction)] = [
            (.approveIncoming, .resolveApproval(.approve)),
            (.rejectIncoming, .resolveApproval(.reject)),
            (.disableInputForActiveSession, .disable(.keyboardAndMouse)),
            (.disableClipboardForActiveSession, .disable(.clipboard)),
            (.disableAudioForActiveSession, .disable(.systemAudio)),
            (.disconnectSession, .disconnect),
        ]

        for (index, item) in cases.enumerated() {
            let request = try makeRequest(
                index: index,
                name: item.0
            )
            let prepared = try XCTUnwrap(service.prepareResponse(
                for: try request.encoded()
            ))
            XCTAssertEqual(recorder.submissions.count, index)
            XCTAssertTrue(prepared.performAfterReply())
        }

        XCTAssertTrue(recorder.waitForSubmissions(cases.count))
        XCTAssertEqual(
            recorder.submissions.map(\.action),
            cases.map(\.1)
        )
        XCTAssertEqual(
            recorder.submissions.map(\.commandID),
            (0..<cases.count).map { "command-\($0)" }
        )
        XCTAssertTrue(recorder.immediateResults.isEmpty)
    }

    func testPreparedTicketDoesNotSubmitUntilPostReplyAction() throws {
        let recorder = CommandExecutionAdapterRecorder()
        let adapter = makeAdapter(recorder: recorder)
        let service = try makeService(adapter: adapter)
        let request = try makeRequest(index: 0, name: .approveIncoming)

        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try request.encoded()
        ))
        XCTAssertTrue(recorder.submissions.isEmpty)

        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertTrue(recorder.waitForSubmissions(1))
        XCTAssertEqual(recorder.submissions.count, 1)
        XCTAssertFalse(prepared.performAfterReply())
        XCTAssertEqual(recorder.submissions.count, 1)
    }

    func testDedicatedQueueSerializesSubmission() throws {
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let recorder = CommandExecutionAdapterRecorder()
        recorder.onSubmit = { submissionIndex in
            if submissionIndex == 0 {
                firstEntered.signal()
                releaseFirst.wait()
            } else if submissionIndex == 1 {
                secondEntered.signal()
            }
        }
        let adapter = makeAdapter(recorder: recorder)
        let service = try makeService(adapter: adapter)
        let first = try XCTUnwrap(service.prepareResponse(
            for: try makeRequest(
                index: 0,
                name: .approveIncoming
            ).encoded()
        ))
        let second = try XCTUnwrap(service.prepareResponse(
            for: try makeRequest(
                index: 1,
                name: .rejectIncoming
            ).encoded()
        ))

        XCTAssertTrue(first.performAfterReply())
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(second.performAfterReply())
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 0.05),
            .timedOut
        )
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(recorder.waitForSubmissions(2))
        XCTAssertEqual(recorder.maximumConcurrentSubmissionCount, 1)
    }

    func testImmediateOutcomePublishesTypedCorrelatedResult() throws {
        let recorder = CommandExecutionAdapterRecorder()
        recorder.outcomes = [
            .rejected(.coreRejected),
            .failed(.coreUnavailable),
        ]
        let adapter = makeAdapter(recorder: recorder)
        let service = try makeService(adapter: adapter)

        for index in 0..<2 {
            let prepared = try XCTUnwrap(service.prepareResponse(
                for: try makeRequest(
                    index: index,
                    name: index == 0 ? .approveIncoming : .disconnectSession
                ).encoded()
            ))
            XCTAssertTrue(prepared.performAfterReply())
        }

        XCTAssertTrue(recorder.waitForImmediateResults(2))
        XCTAssertEqual(recorder.immediateResults, [
            try HostAgentXPCWireCommandResult(
                commandID: "command-0",
                status: .rejected,
                detail: "core-rejected"
            ),
            try HostAgentXPCWireCommandResult(
                commandID: "command-1",
                status: .error,
                detail: "core-unavailable"
            ),
        ])
    }

    func testCancelBeforePostReplyActionEmitsStoppingResultWithoutSubmit()
        throws
    {
        let recorder = CommandExecutionAdapterRecorder()
        let adapter = makeAdapter(recorder: recorder)
        let service = try makeService(adapter: adapter)
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try makeRequest(
                index: 0,
                name: .disconnectSession
            ).encoded()
        ))

        XCTAssertTrue(adapter.cancelAndWait(timeout: .now() + 2))
        XCTAssertEqual(adapter.stateSnapshot(), .cancelled)
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertTrue(recorder.waitForImmediateResults(1))
        XCTAssertTrue(recorder.submissions.isEmpty)
        XCTAssertEqual(
            recorder.immediateResults.first,
            try HostAgentXPCWireCommandResult(
                commandID: "command-0",
                status: .error,
                detail: "agent-stopping"
            )
        )

        XCTAssertNil(service.prepareResponse(
            for: try makeRequest(
                index: 1,
                name: .approveIncoming
            ).encoded()
        ))
    }

    func testCancelWaitsForAlreadyEnqueuedSubmission() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let recorder = CommandExecutionAdapterRecorder()
        recorder.onSubmit = { _ in
            entered.signal()
            release.wait()
        }
        let adapter = makeAdapter(recorder: recorder)
        let service = try makeService(adapter: adapter)
        let prepared = try XCTUnwrap(service.prepareResponse(
            for: try makeRequest(
                index: 0,
                name: .approveIncoming
            ).encoded()
        ))
        XCTAssertTrue(prepared.performAfterReply())
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            XCTAssertTrue(adapter.cancelAndWait(timeout: .now() + 2))
            cancelled.signal()
        }
        XCTAssertEqual(
            cancelled.wait(timeout: .now() + 0.05),
            .timedOut
        )
        release.signal()
        XCTAssertEqual(cancelled.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(recorder.waitForSubmissions(1))
    }

    func testSourceOwnsNoXPCTransportJournalHostClientOrExternalState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCCommandExecutionAdapter.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPC"))
        XCTAssertFalse(source.contains("HostAgentEventState"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("rdn_host"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("UserDefaults"))
    }

    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    private func makeAdapter(
        recorder: CommandExecutionAdapterRecorder
    ) -> HostAgentXPCCommandExecutionAdapter {
        HostAgentXPCCommandExecutionAdapter(
            submit: { submission in recorder.submit(submission) },
            onImmediateResult: { result in
                recorder.recordImmediateResult(result)
            }
        )
    }

    private func makeService(
        adapter: HostAgentXPCCommandExecutionAdapter
    ) throws -> HostAgentXPCCommandService {
        let identity = try HostAgentXPCWireAgentIdentity.test(
            agentBuildID: "agent-build",
            hostInstanceID: "host-a",
            agentBootID: bootID
        )
        return HostAgentXPCCommandService(
            identity: identity,
            authority: try HostAgentXPCCommandAdmissionAuthority(
                identity: identity
            ),
            prepareExecution: { execution in
                adapter.prepare(execution)
            },
            publishResult: { _ in true },
            nowUnixMilliseconds: { 20 }
        )
    }

    private func makeRequest(
        index: Int,
        name: HostAgentXPCWireCommandName
    ) throws -> HostAgentXPCWireCommandRequest {
        let requestIDs = [
            "287fd5f2-98b7-4183-ac81-6973cef9a610",
            "151db9a9-7dd3-4fea-93af-1b6c10840676",
            "841733af-919b-4dc2-84bb-7134d0951dc9",
            "62113cb8-4d8c-43ec-8e84-a92b77ed2ce7",
            "9f28662b-bd6c-47df-890f-48b4f8774557",
            "7f8207d1-1ea3-4d90-9efe-bcac72ba1d54",
        ]
        return try HostAgentXPCWireCommandRequest(
            requestID: requestIDs[index],
            commandID: "command-\(index)",
            wireVersion: 2,
            hostInstanceID: "host-a",
            agentBootID: bootID,
            name: name,
            connectionID: "host-a:connection-1",
            sentAtUnixMilliseconds: 10
        )
    }
}

private final class CommandExecutionAdapterRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    var outcomes: [HostAgentXPCCommandSubmissionOutcome] = []
    var onSubmit: (@Sendable (Int) -> Void)?
    private(set) var submissions: [HostAgentCoreCommandSubmission] = []
    private(set) var immediateResults: [HostAgentXPCWireCommandResult] = []
    private(set) var maximumConcurrentSubmissionCount = 0
    private var activeSubmissionCount = 0

    func submit(
        _ submission: HostAgentCoreCommandSubmission
    ) -> HostAgentXPCCommandSubmissionOutcome {
        condition.lock()
        let index = submissions.count
        submissions.append(submission)
        activeSubmissionCount += 1
        maximumConcurrentSubmissionCount = max(
            maximumConcurrentSubmissionCount,
            activeSubmissionCount
        )
        let outcome = outcomes.isEmpty
            ? .awaitingCoreResult
            : outcomes.removeFirst()
        let callback = onSubmit
        condition.broadcast()
        condition.unlock()

        callback?(index)

        condition.lock()
        activeSubmissionCount -= 1
        condition.broadcast()
        condition.unlock()
        return outcome
    }

    func recordImmediateResult(_ result: HostAgentXPCWireCommandResult) {
        condition.lock()
        immediateResults.append(result)
        condition.broadcast()
        condition.unlock()
    }

    func waitForSubmissions(_ count: Int) -> Bool {
        waitUntil { submissions.count >= count && activeSubmissionCount == 0 }
    }

    func waitForImmediateResults(_ count: Int) -> Bool {
        waitUntil { immediateResults.count >= count }
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        condition.lock()
        defer { condition.unlock() }
        while !predicate() {
            if !condition.wait(until: deadline) { return predicate() }
        }
        return true
    }
}
