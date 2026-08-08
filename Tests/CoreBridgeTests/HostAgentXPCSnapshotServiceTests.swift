@testable import CoreBridge
import CoreBridgeShim
import Foundation
import XCTest

final class HostAgentXPCSnapshotServiceTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testFactoryConstructsHandshakeSnapshotAndEventMethodInterface() throws {
        let interface = HostAgentXPCSnapshotInterfaceFactory.makeInterface()

        XCTAssertEqual(
            NSStringFromProtocol(interface.protocol),
            "RDNHostAgentXPCEventService"
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
        XCTAssertEqual(header.components(separatedBy: "- (void)").count - 1, 3)
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

    func testAnonymousXPCConnectionPerformsHandshakeThenSnapshotRoundTrip() throws {
        let clock = SnapshotServiceTestClock(values: [1_000, 2_000])
        let handler = try makeHandler(
            availableSnapshot: true,
            eventSequence: 7,
            eventState: makeEventState(count: 7),
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
            } as? RDNHostAgentXPCEventService
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
    }

    func testServiceSourceCannotOwnConnectionOrExposeEventsAndCommands() throws {
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
        XCTAssertFalse(source.contains("HostAgentXPCWireCommand"))
        XCTAssertTrue(source.contains("HostAgentXPCWireEvent"))
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
