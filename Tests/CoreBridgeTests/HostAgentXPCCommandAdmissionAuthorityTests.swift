@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCCommandAdmissionAuthorityTests: XCTestCase {
    func testRejectsInvalidCapacity() throws {
        let identity = try makeIdentity()
        for capacity in [0, 1_025] {
            XCTAssertThrowsError(
                try HostAgentXPCCommandAdmissionAuthority(
                    identity: identity,
                    capacity: capacity
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentXPCCommandAdmissionConfigurationError,
                    .invalidCapacity
                )
            }
        }
    }

    func testReservationMustBeMarkedQueuedBeforeDuplicateCanAcknowledge()
        throws
    {
        let authority = try makeAuthority()
        let request = try makeRequest()
        guard case .reserved(let reservation) = authority.reserve(request)
        else { return XCTFail("expected reservation") }

        XCTAssertEqual(authority.reserve(request), .pendingQueue)
        XCTAssertEqual(authority.snapshot().reservedCount, 1)
        XCTAssertTrue(authority.markQueued(reservation))
        XCTAssertFalse(authority.markQueued(reservation))
        XCTAssertEqual(authority.reserve(request), .alreadyQueued)

        let snapshot = authority.snapshot()
        XCTAssertEqual(snapshot.retainedCount, 1)
        XCTAssertEqual(snapshot.reservedCount, 0)
        XCTAssertEqual(snapshot.queuedCount, 1)
        XCTAssertEqual(snapshot.completedCount, 0)
    }

    func testCancellingExactReservationAllowsFreshRetry() throws {
        let authority = try makeAuthority()
        let request = try makeRequest()
        guard case .reserved(let first) = authority.reserve(request)
        else { return XCTFail("expected reservation") }

        XCTAssertTrue(authority.cancelReservation(first))
        XCTAssertFalse(authority.cancelReservation(first))
        guard case .reserved(let second) = authority.reserve(request)
        else { return XCTFail("expected fresh reservation") }
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(authority.markQueued(first))
        XCTAssertTrue(authority.markQueued(second))
    }

    func testCompletedResultIsReplayedWithoutNewExecution() throws {
        let authority = try makeAuthority()
        let request = try makeRequest()
        let reservation = try reserve(request, in: authority)
        XCTAssertTrue(authority.markQueued(reservation))
        let result = try commandResult(commandID: request.commandID)

        XCTAssertEqual(authority.recordResult(result), .recorded)
        let retry = try makeRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676"
        )
        XCTAssertEqual(authority.reserve(retry), .replay(result))
        XCTAssertEqual(authority.recordResult(result), .unchanged)

        let snapshot = authority.snapshot()
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.queuedCount, 0)
    }

    func testConflictingPayloadRejectsWithoutReplacingOriginal() throws {
        let authority = try makeAuthority()
        let original = try makeRequest()
        let reservation = try reserve(original, in: authority)
        XCTAssertTrue(authority.markQueued(reservation))

        let conflictingName = try makeRequest(
            name: .rejectIncoming
        )
        let conflictingTarget = try makeRequest(
            connectionID: "host-a:connection-2"
        )
        XCTAssertEqual(
            authority.reserve(conflictingName),
            .rejected(.conflictingPayload)
        )
        XCTAssertEqual(
            authority.reserve(conflictingTarget),
            .rejected(.conflictingPayload)
        )
        XCTAssertEqual(authority.reserve(original), .alreadyQueued)
    }

    func testConflictingRecordedResultPermanentlyInvalidatesAuthority()
        throws
    {
        let authority = try makeAuthority()
        let request = try makeRequest()
        let reservation = try reserve(request, in: authority)
        XCTAssertTrue(authority.markQueued(reservation))
        let first = try commandResult(
            commandID: request.commandID,
            status: .ok,
            detail: "queued"
        )
        let conflicting = try commandResult(
            commandID: request.commandID,
            status: .error,
            detail: "internal-error"
        )
        XCTAssertEqual(authority.recordResult(first), .recorded)
        XCTAssertEqual(authority.recordResult(conflicting), .invalidated)
        XCTAssertEqual(authority.snapshot().state, .invalidated)
        XCTAssertEqual(
            authority.reserve(request),
            .rejected(.invalidated)
        )
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
    }

    func testResultBeforeQueuedPermanentlyInvalidatesAuthority() throws {
        let authority = try makeAuthority()
        let request = try makeRequest()
        _ = try reserve(request, in: authority)

        XCTAssertEqual(
            authority.recordResult(try commandResult(
                commandID: request.commandID
            )),
            .invalidated
        )
        XCTAssertEqual(authority.snapshot().state, .invalidated)
    }

    func testUnknownResultIsRejectedWithoutPoisoningTrackedCommands()
        throws
    {
        let authority = try makeAuthority()
        XCTAssertEqual(
            authority.recordResult(try commandResult(commandID: "unknown")),
            .unknownCommand
        )
        XCTAssertEqual(authority.snapshot().state, .active)
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
    }

    func testForeignIdentityIsRejectedWithoutConsumingCapacity() throws {
        let authority = try makeAuthority(capacity: 1)
        let foreignHost = try makeRequest(hostID: "host-b")
        let foreignBoot = try makeRequest(
            bootID: "5dd81b11-0f26-4d13-bc33-72fd0eff6c28"
        )

        XCTAssertEqual(
            authority.reserve(foreignHost),
            .rejected(.foreignIdentity)
        )
        XCTAssertEqual(
            authority.reserve(foreignBoot),
            .rejected(.foreignIdentity)
        )
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
        _ = try reserve(makeRequest(), in: authority)
        XCTAssertEqual(authority.snapshot().retainedCount, 1)
    }

    func testCapacityNeverEvictsReservedOrQueuedCommands() throws {
        let authority = try makeAuthority(capacity: 2)
        let first = try makeRequest(commandID: "command-1")
        let second = try makeRequest(commandID: "command-2")
        let third = try makeRequest(commandID: "command-3")
        _ = try reserve(first, in: authority)
        let secondReservation = try reserve(second, in: authority)
        XCTAssertTrue(authority.markQueued(secondReservation))

        XCTAssertEqual(
            authority.reserve(third),
            .rejected(.capacityExhausted)
        )
        let snapshot = authority.snapshot()
        XCTAssertEqual(snapshot.reservedCount, 1)
        XCTAssertEqual(snapshot.queuedCount, 1)
        XCTAssertEqual(snapshot.evictedCompletedCount, 0)
    }

    func testCapacityEvictsOldestCompletedResultAsExplicitWindowBoundary()
        throws
    {
        let authority = try makeAuthority(capacity: 2)
        let first = try makeRequest(commandID: "command-1")
        let second = try makeRequest(commandID: "command-2")
        let third = try makeRequest(commandID: "command-3")

        try complete(first, in: authority, detail: "first")
        try complete(second, in: authority, detail: "second")
        _ = try reserve(third, in: authority)

        let snapshot = authority.snapshot()
        XCTAssertEqual(snapshot.retainedCount, 2)
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.reservedCount, 1)
        XCTAssertEqual(snapshot.evictedCompletedCount, 1)
        guard case .reserved = authority.reserve(first) else {
            return XCTFail("evicted command must be outside dedupe window")
        }
        XCTAssertEqual(authority.snapshot().evictedCompletedCount, 2)
    }

    func testConcurrentSameCommandProducesOneReservation() throws {
        let authority = try makeAuthority(capacity: 64)
        let request = try makeRequest()
        let lock = NSLock()
        var results: [HostAgentXPCCommandAdmissionResult] = []
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "HostAgentXPCCommandAdmissionAuthorityTests.concurrent",
            attributes: .concurrent
        )

        for _ in 0..<64 {
            group.enter()
            queue.async {
                let result = authority.reserve(request)
                lock.lock()
                results.append(result)
                lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        let reservations = results.compactMap { result ->
            HostAgentXPCCommandReservation? in
            guard case .reserved(let reservation) = result else { return nil }
            return reservation
        }
        XCTAssertEqual(reservations.count, 1)
        XCTAssertEqual(results.filter { $0 == .pendingQueue }.count, 63)
        XCTAssertTrue(authority.markQueued(try XCTUnwrap(reservations.first)))
        XCTAssertEqual(authority.reserve(request), .alreadyQueued)
    }

    func testExplicitInvalidationClearsWindowAndIsTerminal() throws {
        let authority = try makeAuthority()
        _ = try reserve(makeRequest(), in: authority)
        authority.invalidate()
        authority.invalidate()

        XCTAssertEqual(authority.snapshot().state, .invalidated)
        XCTAssertEqual(authority.snapshot().retainedCount, 0)
        XCTAssertEqual(
            authority.reserve(try makeRequest()),
            .rejected(.invalidated)
        )
    }

    func testSourceOwnsNoXPCExecutionOrExternalPersistence() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCCommandAdmissionAuthority.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCInterface"))
        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("rdn_host"))
        XCTAssertFalse(source.contains("DispatchQueue"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("UserDefaults"))
    }

    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    private func makeAuthority(
        capacity: Int = 256
    ) throws -> HostAgentXPCCommandAdmissionAuthority {
        try HostAgentXPCCommandAdmissionAuthority(
            identity: makeIdentity(),
            capacity: capacity
        )
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
        bootID: String? = nil,
        name: HostAgentXPCWireCommandName = .approveIncoming,
        connectionID: String? = nil
    ) throws -> HostAgentXPCWireCommandRequest {
        try HostAgentXPCWireCommandRequest(
            requestID: requestID,
            commandID: commandID,
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID ?? self.bootID,
            name: name,
            connectionID: connectionID ?? "\(hostID):connection-1",
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

    private func reserve(
        _ request: HostAgentXPCWireCommandRequest,
        in authority: HostAgentXPCCommandAdmissionAuthority
    ) throws -> HostAgentXPCCommandReservation {
        guard case .reserved(let reservation) = authority.reserve(request)
        else { throw TestFailure.expectedReservation }
        return reservation
    }

    private func complete(
        _ request: HostAgentXPCWireCommandRequest,
        in authority: HostAgentXPCCommandAdmissionAuthority,
        detail: String
    ) throws {
        let reservation = try reserve(request, in: authority)
        guard authority.markQueued(reservation) else {
            throw TestFailure.expectedQueued
        }
        guard authority.recordResult(try commandResult(
            commandID: request.commandID,
            detail: detail
        )) == .recorded else {
            throw TestFailure.expectedRecorded
        }
    }
}

private enum TestFailure: Error {
    case expectedReservation
    case expectedQueued
    case expectedRecorded
}
