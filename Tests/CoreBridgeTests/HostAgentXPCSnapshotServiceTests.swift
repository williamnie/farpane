@testable import CoreBridge
import CoreBridgeShim
import Foundation
import XCTest

final class HostAgentXPCSnapshotServiceTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testFactoryConstructsHandshakeSnapshotEventAndCommandInterface() throws {
        let interface = HostAgentXPCSnapshotInterfaceFactory.makeInterface()

        XCTAssertEqual(
            NSStringFromProtocol(interface.protocol),
            "RDNHostAgentXPCCommandService"
        )
        XCTAssertEqual(
            HostAgentXPCSnapshotInterfaceFactory.handshakeSelectorName,
            "performHandshakeWithRequestData:reply:"
        )
        XCTAssertEqual(
            HostAgentXPCSnapshotInterfaceFactory.snapshotSelectorName,
            "fetchSnapshotWithRequestData:reply:"
        )
        XCTAssertEqual(
            HostAgentXPCSnapshotInterfaceFactory.eventSelectorName,
            "fetchEventsWithRequestData:reply:"
        )
        XCTAssertEqual(
            HostAgentXPCSnapshotInterfaceFactory.commandSelectorName,
            "submitCommandWithRequestData:reply:"
        )

        let header = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "CoreBridge/include/HostAgentXPCHandshakeService.h"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(header.contains(
            "RDNHostAgentXPCSnapshotService <RDNHostAgentXPCHandshakeService>"
        ))
        XCTAssertTrue(header.contains(
            "RDNHostAgentXPCEventService <RDNHostAgentXPCSnapshotService>"
        ))
        XCTAssertTrue(header.contains(
            "RDNHostAgentXPCCommandService <RDNHostAgentXPCEventService>"
        ))
        XCTAssertEqual(header.components(separatedBy: "- (void)").count - 1, 4)
        XCTAssertTrue(header.contains("NSData *)requestData"))
        XCTAssertTrue(header.contains("NSData * _Nullable responseData"))
        XCTAssertFalse(header.contains("NSArray"))
        XCTAssertFalse(header.contains("NSDictionary"))
        XCTAssertFalse(header.contains("NSURL"))
        XCTAssertFalse(header.contains("NSError"))
    }

    func testSnapshotFailsClosedBeforeCompatibleHandshake() throws {
        let handler = try makeHandler(availableSnapshot: true)
        var replies: [Data?] = []

        handler.fetchSnapshot(requestData: try snapshotRequest().encoded()) {
            replies.append($0)
        }

        XCTAssertEqual(replies.count, 1)
        XCTAssertNil(replies[0])
        XCTAssertEqual(handler.stateSnapshot(), .awaitingHandshake)
    }

    func testCompatibleHandshakeUnlocksOnlyCorrelatedAvailableSnapshot() throws {
        let handler = try makeHandler(availableSnapshot: true, eventSequence: 7)
        let handshake = try handshakeRequest(versions: [1])

        let handshakeData = try XCTUnwrap(handler.handshakeResponse(
            for: handshake.encoded()
        ))
        let handshakeResponse = try HostAgentXPCWireHandshakeResponse.decode(
            handshakeData
        )
        XCTAssertEqual(handshakeResponse.compatibility, .compatible)
        XCTAssertEqual(handler.stateSnapshot(), .compatible(wireVersion: 1))

        let request = try snapshotRequest()
        let snapshotData = try XCTUnwrap(handler.snapshotResponse(
            for: request.encoded()
        ))
        let response = try HostAgentXPCWireSnapshotResponse.decode(snapshotData)
        XCTAssertEqual(response.evaluate(for: request), .correlated)
        XCTAssertEqual(response.lastEventID, 7)
        XCTAssertEqual(response.snapshot.hostState, "ready")

        let wrongBoot = try HostAgentXPCWireSnapshotRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            sentAtUnixMilliseconds: 12
        )
        XCTAssertNil(handler.snapshotResponse(for: try wrongBoot.encoded()))
        XCTAssertNil(handler.handshakeResponse(for: try handshake.encoded()))
    }

    func testIncompatibleHandshakeTerminallyRejectsSnapshotAndRenegotiation() throws {
        let handler = try makeHandler(availableSnapshot: true)
        let incompatible = try handshakeRequest(versions: [2])
        let incompatibleData = try XCTUnwrap(handler.handshakeResponse(
            for: incompatible.encoded()
        ))
        XCTAssertEqual(
            try HostAgentXPCWireHandshakeResponse.decode(incompatibleData)
                .compatibility,
            .incompatible
        )
        XCTAssertEqual(handler.stateSnapshot(), .incompatible)

        XCTAssertNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
        XCTAssertNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
    }

    func testMalformedHandshakeCanRetryButUnavailableSnapshotStillFailsClosed() throws {
        let handler = try makeHandler(availableSnapshot: false)

        XCTAssertNil(handler.handshakeResponse(for: Data()))
        XCTAssertEqual(handler.stateSnapshot(), .awaitingHandshake)
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertEqual(handler.stateSnapshot(), .compatible(wireVersion: 1))

        XCTAssertNil(handler.snapshotResponse(for: Data()))
        XCTAssertNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
    }

    func testConcurrentHandshakeAllowsExactlyOneTerminalNegotiation() throws {
        let handler = try makeHandler(availableSnapshot: true)
        let requestData = try handshakeRequest(versions: [1]).encoded()
        let queue = DispatchQueue(
            label: "HostAgentXPCSnapshotServiceTests.handshake",
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let lock = NSLock()
        var successfulReplies = 0

        for _ in 0..<32 {
            group.enter()
            queue.async {
                if handler.handshakeResponse(for: requestData) != nil {
                    lock.lock()
                    successfulReplies += 1
                    lock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(successfulReplies, 1)
        XCTAssertEqual(handler.stateSnapshot(), .compatible(wireVersion: 1))
    }

    func testSnapshotRequestsAreRateLimitedPerConnection() throws {
        let clock = SnapshotServiceTestClock(values: [1_000, 1_099, 1_100])
        let handler = try makeHandler(
            availableSnapshot: true,
            monotonicMilliseconds: { clock.now() }
        )
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        let requestData = try snapshotRequest().encoded()

        XCTAssertNotNil(handler.snapshotResponse(for: requestData))
        XCTAssertNil(handler.snapshotResponse(for: requestData))
        XCTAssertNotNil(handler.snapshotResponse(for: requestData))
    }

    func testEventFailsClosedUntilSnapshotThenAdvancesExactCursor() throws {
        let eventState = try makeEventState(count: 2)
        let clock = SnapshotServiceTestClock(values: [1_000, 2_000, 2_100])
        let handler = try makeHandler(
            availableSnapshot: true,
            eventSequence: 0,
            eventState: eventState,
            monotonicMilliseconds: { clock.now() }
        )
        let initialEventRequest = try eventRequest(afterEventID: 0)

        XCTAssertNil(handler.eventResponse(
            for: try initialEventRequest.encoded()
        ))
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertNil(handler.eventResponse(
            for: try initialEventRequest.encoded()
        ))
        XCTAssertNotNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))

        let eventData = try XCTUnwrap(handler.eventResponse(
            for: initialEventRequest.encoded()
        ))
        let response = try HostAgentXPCWireEventCursorResponse.decode(eventData)
        XCTAssertEqual(response.outcome, .batch)
        XCTAssertEqual(response.resumeAfterEventID, 2)
        XCTAssertEqual(response.latestEventID, 2)
        XCTAssertEqual(
            handler.stateSnapshot(),
            .snapshotReady(wireVersion: 1, afterEventID: 2)
        )

        XCTAssertNil(handler.eventResponse(
            for: try initialEventRequest.encoded()
        ))
        let caughtUp = try eventRequest(afterEventID: 2)
        let caughtUpData = try XCTUnwrap(handler.eventResponse(
            for: caughtUp.encoded()
        ))
        XCTAssertEqual(
            try HostAgentXPCWireEventCursorResponse.decode(caughtUpData).outcome,
            .upToDate
        )
    }

    func testGapRequiresAnotherSnapshotBeforeAnyEventRetry() throws {
        let eventState = try HostAgentEventState(
            capacity: 2,
            maximumEventBytes: 4_096
        )
        let clock = SnapshotServiceTestClock(values: [1_000, 2_000])
        let handler = try makeHandler(
            availableSnapshot: true,
            eventSequence: 0,
            eventState: eventState,
            monotonicMilliseconds: { clock.now() }
        )
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertNotNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
        for eventID in 1...3 {
            _ = eventState.ingest(try event(id: UInt64(eventID)))
        }

        let request = try eventRequest(afterEventID: 0)
        let data = try XCTUnwrap(handler.eventResponse(
            for: request.encoded()
        ))
        XCTAssertEqual(
            try HostAgentXPCWireEventCursorResponse.decode(data).outcome,
            .gap
        )
        XCTAssertEqual(handler.stateSnapshot(), .compatible(wireVersion: 1))
        XCTAssertNil(handler.eventResponse(for: try request.encoded()))
    }

    func testEventRequestsAreRateLimitedIndependentlyFromSnapshot() throws {
        let clock = SnapshotServiceTestClock(
            values: [1_000, 2_000, 2_099, 2_100]
        )
        let handler = try makeHandler(
            availableSnapshot: true,
            eventSequence: 0,
            monotonicMilliseconds: { clock.now() }
        )
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertNotNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
        let requestData = try eventRequest(afterEventID: 0).encoded()

        XCTAssertNotNil(handler.eventResponse(for: requestData))
        XCTAssertNil(handler.eventResponse(for: requestData))
        XCTAssertNotNil(handler.eventResponse(for: requestData))
    }

    func testCommandFailsClosedUntilSnapshotAndForForeignIdentity() throws {
        let recorder = SnapshotCommandServiceRecorder()
        let service = try makeCommandService(recorder: recorder)
        let clock = SnapshotServiceTestClock(values: [1_000, 2_000])
        let handler = try makeHandler(
            availableSnapshot: true,
            commandService: service,
            monotonicMilliseconds: { clock.now() }
        )
        let request = try commandRequest()

        XCTAssertNil(commandReply(
            handler,
            requestData: try request.encoded()
        ))
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertNil(commandReply(
            handler,
            requestData: try request.encoded()
        ))
        XCTAssertNotNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
        XCTAssertNil(commandReply(
            handler,
            requestData: try commandRequest(
                bootID: "287fd5f2-98b7-4183-ac81-6973cef9a610"
            ).encoded()
        ))
        XCTAssertEqual(recorder.preparedExecutions.count, 0)

        let responseData = try XCTUnwrap(commandReply(
            handler,
            requestData: try request.encoded()
        ))
        XCTAssertEqual(
            try HostAgentXPCWireCommandAcceptedResponse.decode(responseData)
                .evaluate(for: request),
            .correlated
        )
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(recorder.startedExecutions.count, 1)
        XCTAssertEqual(
            handler.stateSnapshot(),
            .snapshotReady(wireVersion: 1, afterEventID: 1)
        )
    }

    func testCommandRepliesBeforeOneShotExecutionAndRejectsReentry() throws {
        let recorder = SnapshotCommandServiceRecorder()
        let service = try makeCommandService(recorder: recorder)
        let clock = SnapshotServiceTestClock(values: [1_000, 2_000, 2_100])
        let handler = try makeHandler(
            availableSnapshot: true,
            commandService: service,
            monotonicMilliseconds: { clock.now() }
        )
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertNotNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
        let request = try commandRequest()
        recorder.ticketFactory = { execution in
            HostAgentXPCCommandQueueTicket {
                XCTAssertEqual(
                    handler.stateSnapshot(),
                    .submittingCommand(
                        wireVersion: 1,
                        afterEventID: 1
                    )
                )
                recorder.recordStarted(execution, marker: "execution")
            }
        }
        var responseData: Data?
        var reentrantData: Data?
        let requestData = try request.encoded()

        handler.submitCommand(requestData: requestData) { data in
            recorder.recordMarker("reply")
            responseData = data
            handler.submitCommand(requestData: requestData) {
                reentrantData = $0
                recorder.recordMarker("reentrant-rejected")
            }
        }

        XCTAssertNotNil(responseData)
        XCTAssertNil(reentrantData)
        XCTAssertEqual(
            recorder.markers,
            ["reply", "reentrant-rejected", "execution"]
        )
        XCTAssertEqual(recorder.startedExecutions.count, 1)
        XCTAssertNotNil(commandReply(
            handler,
            requestData: try commandRequest(
                requestID: "841733af-919b-4dc2-84bb-7134d0951dc9"
            ).encoded()
        ))
        XCTAssertEqual(recorder.preparedExecutions.count, 1)
        XCTAssertEqual(recorder.startedExecutions.count, 1)
    }

    func testCommandRequestsAreRateLimitedPerConnection() throws {
        let recorder = SnapshotCommandServiceRecorder()
        let service = try makeCommandService(recorder: recorder)
        let clock = SnapshotServiceTestClock(
            values: [1_000, 2_000, 2_099, 2_100]
        )
        let handler = try makeHandler(
            availableSnapshot: true,
            commandService: service,
            monotonicMilliseconds: { clock.now() }
        )
        XCTAssertNotNil(handler.handshakeResponse(
            for: try handshakeRequest(versions: [1]).encoded()
        ))
        XCTAssertNotNil(handler.snapshotResponse(
            for: try snapshotRequest().encoded()
        ))
        XCTAssertNotNil(commandReply(
            handler,
            requestData: try commandRequest().encoded()
        ))
        let second = try commandRequest(
            requestID: "841733af-919b-4dc2-84bb-7134d0951dc9",
            commandID: "command-2"
        )

        XCTAssertNil(commandReply(handler, requestData: try second.encoded()))
        XCTAssertNotNil(commandReply(
            handler,
            requestData: try second.encoded()
        ))
        XCTAssertEqual(recorder.preparedExecutions.count, 2)
        XCTAssertEqual(recorder.startedExecutions.count, 2)
    }

    func testAnonymousXPCConnectionPerformsSnapshotFirstCommandRoundTrip() throws {
        let commandRecorder = SnapshotCommandServiceRecorder()
        let clock = SnapshotServiceTestClock(values: [1_000, 2_000, 2_100])
        let handler = try makeHandler(
            availableSnapshot: true,
            eventSequence: 7,
            eventState: makeEventState(count: 7),
            commandService: makeCommandService(recorder: commandRecorder),
            monotonicMilliseconds: { clock.now() }
        )
        let interface = HostAgentXPCSnapshotInterfaceFactory.makeInterface()
        let listener = NSXPCListener.anonymous()
        let delegate = SnapshotServiceTestListenerDelegate(
            interface: interface,
            handler: handler
        )
        listener.delegate = delegate
        listener.resume()
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = interface
        connection.resume()
        defer {
            connection.invalidate()
            listener.invalidate()
        }
        let proxy = try XCTUnwrap(
            connection.remoteObjectProxyWithErrorHandler { error in
                XCTFail("anonymous XPC error: \(error.localizedDescription)")
            } as? RDNHostAgentXPCCommandService
        )

        let handshakeReply = expectation(description: "handshake reply")
        var handshakeData: Data?
        proxy.performHandshake(
            requestData: try handshakeRequest(versions: [1]).encoded()
        ) { data in
            handshakeData = data
            handshakeReply.fulfill()
        }
        wait(for: [handshakeReply], timeout: 2)
        XCTAssertEqual(
            try HostAgentXPCWireHandshakeResponse.decode(
                XCTUnwrap(handshakeData)
            ).compatibility,
            .compatible
        )

        let snapshotReply = expectation(description: "snapshot reply")
        var snapshotData: Data?
        proxy.fetchSnapshot(requestData: try snapshotRequest().encoded()) {
            data in
            snapshotData = data
            snapshotReply.fulfill()
        }
        wait(for: [snapshotReply], timeout: 2)
        let response = try HostAgentXPCWireSnapshotResponse.decode(
            XCTUnwrap(snapshotData)
        )
        XCTAssertEqual(response.lastEventID, 7)
        XCTAssertEqual(response.snapshot.hostState, "ready")

        let eventReply = expectation(description: "event reply")
        var eventData: Data?
        proxy.fetchEvents(requestData: try eventRequest(
            afterEventID: 7
        ).encoded()) { data in
            eventData = data
            eventReply.fulfill()
        }
        wait(for: [eventReply], timeout: 2)
        XCTAssertEqual(
            try HostAgentXPCWireEventCursorResponse.decode(
                XCTUnwrap(eventData)
            ).outcome,
            .upToDate
        )

        let command = try commandRequest()
        let commandReply = expectation(description: "command reply")
        var commandData: Data?
        proxy.submitCommand(requestData: try command.encoded()) { data in
            commandData = data
            commandReply.fulfill()
        }
        wait(for: [commandReply], timeout: 2)
        XCTAssertEqual(
            try HostAgentXPCWireCommandAcceptedResponse.decode(
                XCTUnwrap(commandData)
            ).evaluate(for: command),
            .correlated
        )
        XCTAssertEqual(commandRecorder.startedExecutions.count, 1)
    }

    func testServiceSourceCannotOwnConnectionHostCoreOrExternalState() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentXPCSnapshotService.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NSXPCListener"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("shouldAcceptNewConnection"))
        XCTAssertFalse(source.contains("activate()"))
        XCTAssertFalse(source.contains("resume()"))
        XCTAssertFalse(source.contains("exportedObject"))
        XCTAssertFalse(source.contains("remoteObject"))
        XCTAssertTrue(source.contains("HostAgentXPCWireCommand"))
        XCTAssertTrue(source.contains("HostAgentXPCWireEvent"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("rdn_host"))
        XCTAssertFalse(source.contains("FileManager"))
        XCTAssertFalse(source.contains("UserDefaults"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeHandler(
        availableSnapshot: Bool,
        eventSequence: UInt64 = 1,
        eventState: HostAgentEventState? = nil,
        commandService: HostAgentXPCCommandService? = nil,
        nowUnixMilliseconds: @escaping HostAgentXPCHandshakeHandler.Clock = {
            20
        },
        monotonicMilliseconds: @escaping
            HostAgentXPCSnapshotSessionHandler.MonotonicClock = {
            1
        }
    ) throws -> HostAgentXPCSnapshotSessionHandler {
        let state = HostAgentSnapshotState()
        if availableSnapshot {
            _ = state.publish(
                try coreSnapshot(),
                eventSequence: eventSequence,
                expectedHostInstanceID: hostID
            )
        }
        return try HostAgentXPCSnapshotSessionHandler(
            identity: HostAgentXPCWireAgentIdentity(
                agentBuildID: "agent-build",
                hostInstanceID: hostID,
                agentBootID: bootID
            ),
            snapshotState: state,
            eventState: eventState ?? HostAgentEventState(),
            commandService: commandService,
            nowUnixMilliseconds: nowUnixMilliseconds,
            monotonicMilliseconds: monotonicMilliseconds
        )
    }

    private func handshakeRequest(
        versions: [UInt64]
    ) throws -> HostAgentXPCWireHandshakeRequest {
        try HostAgentXPCWireHandshakeRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            supportedWireVersions: versions,
            appBuildID: "app-build",
            knownHostInstanceID: nil,
            knownAgentBootID: nil,
            sentAtUnixMilliseconds: 10
        )
    }

    private func snapshotRequest() throws -> HostAgentXPCWireSnapshotRequest {
        try HostAgentXPCWireSnapshotRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
    }

    private func eventRequest(
        afterEventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorRequest {
        try HostAgentXPCWireEventCursorRequest(
            requestID: "841733af-919b-4dc2-84bb-7134d0951dc9",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: afterEventID,
            maximumEventCount: 64,
            sentAtUnixMilliseconds: 12
        )
    }

    private func commandRequest(
        requestID: String = "287fd5f2-98b7-4183-ac81-6973cef9a610",
        commandID: String = "command-1",
        bootID: String? = nil
    ) throws -> HostAgentXPCWireCommandRequest {
        try HostAgentXPCWireCommandRequest(
            requestID: requestID,
            commandID: commandID,
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID ?? self.bootID,
            name: .approveIncoming,
            connectionID: "\(hostID):connection-1",
            sentAtUnixMilliseconds: 13
        )
    }

    private func makeCommandService(
        recorder: SnapshotCommandServiceRecorder
    ) throws -> HostAgentXPCCommandService {
        let identity = try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
        return HostAgentXPCCommandService(
            identity: identity,
            authority: try HostAgentXPCCommandAdmissionAuthority(
                identity: identity
            ),
            prepareExecution: { execution in
                recorder.prepare(execution)
            },
            publishResult: { result in
                recorder.publish(result)
            },
            nowUnixMilliseconds: { 20 }
        )
    }

    private func commandReply(
        _ handler: HostAgentXPCSnapshotSessionHandler,
        requestData: Data
    ) -> Data? {
        var result: Data?
        handler.submitCommand(requestData: requestData) { result = $0 }
        return result
    }

    private func makeEventState(count: Int) throws -> HostAgentEventState {
        let state = try HostAgentEventState(
            capacity: max(2, count),
            maximumEventBytes: 4_096
        )
        for eventID in 1...count {
            _ = state.ingest(try event(id: UInt64(eventID)))
        }
        return state
    }

    private func event(id: UInt64) throws -> HostCoreEvent {
        try XCTUnwrap(HostCoreEvent(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "eventId": id,
                "eventType": "snapshotChanged",
                "hostInstanceId": hostID,
                "sentAt": 1_700_000_000_000 as UInt64,
                "payload": [:],
            ]
        )))
    }

    private func coreSnapshot() throws -> HostCoreSnapshot {
        try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 7,
                "hostInstanceId": hostID,
                "hostState": "ready",
                "localId": "123456789",
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

private final class SnapshotServiceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]

    init(values: [UInt64]) {
        self.values = values
    }

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class SnapshotCommandServiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    var ticketFactory: (@Sendable (HostAgentXPCCommandExecution)
        -> HostAgentXPCCommandQueueTicket?)?
    private(set) var preparedExecutions: [HostAgentXPCCommandExecution] = []
    private(set) var startedExecutions: [HostAgentXPCCommandExecution] = []
    private(set) var publishedResults: [HostAgentXPCWireCommandResult] = []
    private(set) var markers: [String] = []

    func prepare(
        _ execution: HostAgentXPCCommandExecution
    ) -> HostAgentXPCCommandQueueTicket? {
        lock.lock()
        preparedExecutions.append(execution)
        let factory = ticketFactory
        lock.unlock()
        return factory?(execution) ?? HostAgentXPCCommandQueueTicket {
            self.recordStarted(execution)
        }
    }

    func publish(_ result: HostAgentXPCWireCommandResult) -> Bool {
        lock.lock()
        publishedResults.append(result)
        lock.unlock()
        return true
    }

    func recordStarted(
        _ execution: HostAgentXPCCommandExecution,
        marker: String? = nil
    ) {
        lock.lock()
        startedExecutions.append(execution)
        if let marker { markers.append(marker) }
        lock.unlock()
    }

    func recordMarker(_ marker: String) {
        lock.lock()
        markers.append(marker)
        lock.unlock()
    }
}

private final class SnapshotServiceTestListenerDelegate:
    NSObject,
    NSXPCListenerDelegate
{
    private let interface: NSXPCInterface
    private let handler: HostAgentXPCSnapshotSessionHandler

    init(
        interface: NSXPCInterface,
        handler: HostAgentXPCSnapshotSessionHandler
    ) {
        self.interface = interface
        self.handler = handler
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = interface
        newConnection.exportedObject = handler
        newConnection.resume()
        return true
    }
}
