@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentXPCHandshakeAdmissionLifecycleTests: XCTestCase {
    func testWaitingIdentityRejectsEligiblePeerWithoutConfiguringConnection() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: false)
        let recorder = HandshakeConnectionRecorder()
        let shell = try makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )

        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(recorder.configureCount, 0)
        XCTAssertEqual(recorder.resumeCount, 0)
        XCTAssertEqual(
            shell.snapshot(),
            HostAgentXPCListenerAdmissionSnapshot(
                connectionAttemptCount: 1,
                rejectedPeerIdentityCount: 0,
                rejectedHandshakeUnavailableCount: 1,
                acceptedHandshakeConnectionCount: 0,
                activeHandshakeConnectionCount: 0,
                closedHandshakeConnectionCount: 0,
                listenerActivated: false,
                cancelled: false
            )
        )
    }

    func testReadyIdentityInstallsHandshakeThenSnapshotServiceAndResumes() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let snapshotState = HostAgentSnapshotState()
        let eventState = try makeEventState(count: 7)
        _ = snapshotState.publish(
            try coreSnapshot(),
            eventSequence: 7,
            expectedHostInstanceID: "host-a"
        )
        let shell = try makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder,
            snapshotState: snapshotState,
            eventState: eventState
        )

        XCTAssertTrue(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(recorder.configureCount, 1)
        XCTAssertEqual(recorder.resumeCount, 1)
        XCTAssertEqual(
            recorder.interfaceProtocolName,
            "RDNHostAgentXPCCommandService"
        )
        XCTAssertNil(try recorder.performValidSnapshot())
        let response = try recorder.performValidHandshake()
        XCTAssertEqual(response.agentBuildID, "agent-build")
        XCTAssertEqual(response.hostInstanceID, "host-a")
        XCTAssertEqual(response.agentBootID, validBootID)
        let snapshot = try XCTUnwrap(recorder.performValidSnapshot())
        XCTAssertEqual(snapshot.lastEventID, 7)
        XCTAssertEqual(snapshot.snapshot.hostState, "ready")
        XCTAssertEqual(
            try recorder.performValidEvents(afterEventID: 7)?.outcome,
            .upToDate
        )
        XCTAssertNil(try recorder.performValidCommand())
        XCTAssertEqual(
            shell.snapshot().activeHandshakeConnectionCount,
            1
        )
    }

    func testInterruptionAndInvalidationCleanupAreIdempotent() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = try makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )
        XCTAssertTrue(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))

        recorder.triggerInterruption()
        recorder.triggerInvalidation()

        XCTAssertEqual(recorder.invalidateCount, 1)
        XCTAssertEqual(shell.snapshot().activeHandshakeConnectionCount, 0)
        XCTAssertEqual(shell.snapshot().closedHandshakeConnectionCount, 1)
    }

    func testAuthorityInvalidationClosesConnectionsAndPermanentlyRejectsNewOnes() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = try makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )
        XCTAssertTrue(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))

        authority.invalidate()

        XCTAssertEqual(recorder.invalidateCount, 1)
        XCTAssertTrue(shell.snapshot().cancelled)
        XCTAssertEqual(shell.snapshot().activeHandshakeConnectionCount, 0)
        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))
        XCTAssertEqual(recorder.configureCount, 1)
        XCTAssertEqual(recorder.resumeCount, 1)
    }

    func testActiveHandshakeConnectionCapacityFailsClosedBeforeConfiguration() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let recorder = HandshakeConnectionRecorder()
        let shell = try makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )

        for _ in 0..<HostAgentXPCListenerAdmissionShell
            .maximumActiveHandshakeConnectionCount
        {
            XCTAssertTrue(shell.listener(
                listener,
                shouldAcceptNewConnection: NSXPCConnection()
            ))
        }
        XCTAssertFalse(shell.listener(
            listener,
            shouldAcceptNewConnection: NSXPCConnection()
        ))

        XCTAssertEqual(
            recorder.configureCount,
            HostAgentXPCListenerAdmissionShell
                .maximumActiveHandshakeConnectionCount
        )
        XCTAssertEqual(recorder.resumeCount, recorder.configureCount)
        XCTAssertEqual(
            shell.snapshot().activeHandshakeConnectionCount,
            UInt64(
                HostAgentXPCListenerAdmissionShell
                    .maximumActiveHandshakeConnectionCount
            )
        )
        XCTAssertEqual(shell.snapshot().rejectedHandshakeUnavailableCount, 1)
    }

    func testListenerActivationRequiresReadyIdentityAndInvalidatesTerminally() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: false)
        let recorder = HandshakeConnectionRecorder()
        let shell = try makeShell(
            listener: listener,
            authority: authority,
            recorder: recorder
        )

        XCTAssertFalse(shell.activate())
        XCTAssertEqual(recorder.listenerActivationCount, 0)
        XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)
        XCTAssertTrue(shell.activate())
        XCTAssertFalse(shell.activate())
        XCTAssertEqual(recorder.listenerActivationCount, 1)
        XCTAssertTrue(shell.snapshot().listenerActivated)

        authority.invalidate()

        XCTAssertEqual(recorder.listenerInvalidationCount, 1)
        XCTAssertFalse(shell.snapshot().listenerActivated)
        XCTAssertTrue(shell.snapshot().cancelled)
        XCTAssertFalse(shell.activate())
    }

    func testConcurrentCancelWaitsForActivationThenInvalidatesListener() throws {
        let listener = NSXPCListener.anonymous()
        let authority = try makeAuthority(ready: true)
        let activationEntered = DispatchSemaphore(value: 0)
        let releaseActivation = DispatchSemaphore(value: 0)
        let activationReturned = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let listenerInvalidated = DispatchSemaphore(value: 0)
        let shell = HostAgentXPCListenerAdmissionShell(
            listener: listener,
            identityAuthority: authority,
            snapshotState: HostAgentSnapshotState(),
            eventState: try HostAgentEventState(),
            assessConnection: { _ in .eligible },
            nowUnixMilliseconds: { 20 },
            monotonicMilliseconds: { 20 },
            configureConnection: { _, _, _, _ in },
            resumeConnection: { _ in },
            invalidateConnection: { _ in },
            activateListener: { _ in
                activationEntered.signal()
                releaseActivation.wait()
            },
            invalidateListener: { _ in
                listenerInvalidated.signal()
            }
        )

        DispatchQueue.global().async {
            XCTAssertTrue(shell.activate())
            activationReturned.signal()
        }
        XCTAssertEqual(activationEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            cancelStarted.signal()
            shell.cancel()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)

        releaseActivation.signal()
        XCTAssertEqual(activationReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(listenerInvalidated.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(shell.snapshot().cancelled)
        XCTAssertFalse(shell.snapshot().listenerActivated)
    }

    private let validBootID = "6973cef9-a610-4183-ac81-287fd5f298b7"

    private func makeAuthority(
        ready: Bool
    ) throws -> HostAgentXPCProcessIdentityAuthority {
        let authority = try HostAgentXPCProcessIdentityAuthority.makeProduct(
            agentBuildID: "agent-build",
            agentBootID: validBootID
        )
        if ready {
            XCTAssertEqual(authority.bind(hostInstanceID: "host-a"), .bound)
        }
        return authority
    }

    private func makeShell(
        listener: NSXPCListener,
        authority: HostAgentXPCProcessIdentityAuthority,
        recorder: HandshakeConnectionRecorder,
        snapshotState: HostAgentSnapshotState = HostAgentSnapshotState(),
        eventState: HostAgentEventState? = nil
    ) throws -> HostAgentXPCListenerAdmissionShell {
        try HostAgentXPCListenerAdmissionShell(
            listener: listener,
            identityAuthority: authority,
            snapshotState: snapshotState,
            eventState: eventState ?? HostAgentEventState(),
            assessConnection: { _ in .eligible },
            nowUnixMilliseconds: { 20 },
            monotonicMilliseconds: { 20 },
            configureConnection: recorder.configure,
            resumeConnection: recorder.resume,
            invalidateConnection: recorder.invalidate,
            activateListener: recorder.activateListener,
            invalidateListener: recorder.invalidateListener
        )
    }

    private func makeEventState(count: Int) throws -> HostAgentEventState {
        let state = try HostAgentEventState(
            capacity: max(2, count),
            maximumEventBytes: 4_096
        )
        for eventID in 1...count {
            let event = try XCTUnwrap(HostCoreEvent(rawJSON:
                JSONSerialization.data(withJSONObject: [
                    "schemaVersion": 1,
                    "eventId": eventID,
                    "eventType": "snapshotChanged",
                    "hostInstanceId": "host-a",
                    "sentAt": 1_700_000_000_000 as UInt64,
                    "payload": [:],
                ])
            ))
            _ = state.ingest(event)
        }
        return state
    }

    private func coreSnapshot() throws -> HostCoreSnapshot {
        try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 6,
                "hostInstanceId": "host-a",
                "hostState": "ready",
                "localId": "123456789",
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

private final class HandshakeConnectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var configuredInterface: NSXPCInterface?
    private var configuredHandler: HostAgentXPCSnapshotSessionHandler?
    private var interruptionHandler: (() -> Void)?
    private var invalidationHandler: (() -> Void)?
    private var configurations = 0
    private var resumes = 0
    private var invalidations = 0
    private var listenerActivations = 0
    private var listenerInvalidations = 0

    var configureCount: Int { locked { configurations } }
    var resumeCount: Int { locked { resumes } }
    var invalidateCount: Int { locked { invalidations } }
    var listenerActivationCount: Int { locked { listenerActivations } }
    var listenerInvalidationCount: Int { locked { listenerInvalidations } }
    var interfaceProtocolName: String? {
        locked {
            configuredInterface.map { NSStringFromProtocol($0.protocol) }
        }
    }

    func configure(
        _ connection: NSXPCConnection,
        _ interface: NSXPCInterface,
        _ handler: HostAgentXPCSnapshotSessionHandler,
        _ lifecycle: HostAgentXPCListenerAdmissionShell
            .ConnectionLifecycleHandlers
    ) {
        lock.lock()
        configurations += 1
        configuredInterface = interface
        configuredHandler = handler
        interruptionHandler = lifecycle.onInterruption
        invalidationHandler = lifecycle.onInvalidation
        lock.unlock()
    }

    func resume(_ connection: NSXPCConnection) {
        lock.lock()
        resumes += 1
        lock.unlock()
    }

    func invalidate(_ connection: NSXPCConnection) {
        lock.lock()
        invalidations += 1
        lock.unlock()
    }

    func activateListener(_ listener: NSXPCListener) {
        lock.lock()
        listenerActivations += 1
        lock.unlock()
    }

    func invalidateListener(_ listener: NSXPCListener) {
        lock.lock()
        listenerInvalidations += 1
        lock.unlock()
    }

    func triggerInterruption() {
        locked { interruptionHandler }?()
    }

    func triggerInvalidation() {
        locked { invalidationHandler }?()
    }

    func performValidHandshake() throws
        -> HostAgentXPCWireHandshakeResponse
    {
        let handler = try XCTUnwrap(locked { configuredHandler })
        let request = try HostAgentXPCWireHandshakeRequest.makeProductRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            appBuildID: "app-build",
            knownHostInstanceID: nil,
            knownAgentBootID: nil,
            sentAtUnixMilliseconds: 10
        )
        let response = try XCTUnwrap(handler.handshakeResponse(
            for: request.encoded()
        ))
        return try HostAgentXPCWireHandshakeResponse.decode(response)
    }

    func performValidSnapshot() throws
        -> HostAgentXPCWireSnapshotResponse?
    {
        let handler = try XCTUnwrap(locked { configuredHandler })
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            sentAtUnixMilliseconds: 11
        )
        guard let response = handler.snapshotResponse(
            for: try request.encoded()
        ) else { return nil }
        return try HostAgentXPCWireSnapshotResponse.decode(response)
    }

    func performValidEvents(
        afterEventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorResponse? {
        let handler = try XCTUnwrap(locked { configuredHandler })
        let request = try HostAgentXPCWireEventCursorRequest(
            requestID: "841733af-919b-4dc2-84bb-7134d0951dc9",
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            afterEventID: afterEventID,
            maximumEventCount: 64,
            sentAtUnixMilliseconds: 12
        )
        guard let response = handler.eventResponse(
            for: try request.encoded()
        ) else { return nil }
        return try HostAgentXPCWireEventCursorResponse.decode(response)
    }

    func performValidCommand() throws -> Data? {
        let handler = try XCTUnwrap(locked { configuredHandler })
        let request = try HostAgentXPCWireCommandRequest(
            requestID: "62113cb8-4d8c-43ec-8e84-a92b77ed2ce7",
            commandID: "command-1",
            wireVersion: 1,
            hostInstanceID: "host-a",
            agentBootID: "6973cef9-a610-4183-ac81-287fd5f298b7",
            name: .approveIncoming,
            connectionID: "host-a:connection-1",
            sentAtUnixMilliseconds: 13
        )
        var response: Data?
        handler.submitCommand(requestData: try request.encoded()) {
            response = $0
        }
        return response
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
