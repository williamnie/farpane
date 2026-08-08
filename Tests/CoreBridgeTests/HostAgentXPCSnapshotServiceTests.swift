@testable import CoreBridge
import CoreBridgeShim
import Foundation
import XCTest

final class HostAgentXPCSnapshotServiceTests: XCTestCase {
    private let hostID = "host-a"
    private let bootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    func testFactoryConstructsHandshakePlusSingleSnapshotMethodInterface() throws {
        let interface = HostAgentXPCSnapshotInterfaceFactory.makeInterface()

        XCTAssertEqual(
            NSStringFromProtocol(interface.protocol),
            "RDNHostAgentXPCSnapshotService"
        )
        XCTAssertEqual(
            HostAgentXPCSnapshotInterfaceFactory.handshakeSelectorName,
            "performHandshakeWithRequestData:reply:"
        )
        XCTAssertEqual(
            HostAgentXPCSnapshotInterfaceFactory.snapshotSelectorName,
            "fetchSnapshotWithRequestData:reply:"
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
        XCTAssertEqual(header.components(separatedBy: "- (void)").count - 1, 2)
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

    func testAnonymousXPCConnectionPerformsHandshakeThenSnapshotRoundTrip() throws {
        let handler = try makeHandler(availableSnapshot: true, eventSequence: 7)
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
            } as? RDNHostAgentXPCSnapshotService
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
        XCTAssertFalse(source.contains("HostAgentXPCWireEvent"))
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
