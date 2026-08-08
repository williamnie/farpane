@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundProjectionAuthorityTests: XCTestCase {
    private let bootA = "6973cef9-a610-4183-ac81-287fd5f298b7"
    private let bootB = "151db9a9-7dd3-4fea-93af-1b6c10840676"

    func testInitialSnapshotPublishesSanitizedAvailableProjection() throws {
        let observations = ProjectionAuthorityRecorder()
        let authority = HostAgentBackgroundProjectionAuthority(
            observer: { observations.append($0) }
        )
        XCTAssertEqual(authority.snapshot().generation, 0)
        XCTAssertEqual(authority.snapshot().phase, .idle)

        let binding = authority.beginSession()
        XCTAssertNil(binding.previousPeerIdentity)
        XCTAssertEqual(observations.values.map(\.phase), [
            .waitingForSnapshot,
        ])
        let peer = try peer(hostID: "host-a", bootID: bootA)
        let response = try snapshotResponse(
            hostID: "host-a",
            bootID: bootA,
            lastEventID: 7,
            localID: "123456789",
            registrationStatus: "ready",
            observedAt: 10
        )

        binding.sink.publishInitialSnapshot(
            response,
            peerIdentity: peer,
            transition: .firstObservation
        )

        let view = authority.snapshot()
        XCTAssertEqual(view.generation, 2)
        XCTAssertEqual(view.handshakeStatus, .compatible)
        XCTAssertEqual(view.snapshotStatus, .available)
        XCTAssertEqual(view.rendezvousStatus, .registered)
        guard case .available(let projection) = view.phase else {
            return XCTFail("expected available projection")
        }
        XCTAssertEqual(projection.peerIdentity, peer)
        XCTAssertEqual(projection.payload, response.snapshot)
        XCTAssertEqual(projection.snapshotEventID, 7)
    }

    func testCommandOnlyEventsAdvancePrivatelyWithoutRepublishingSnapshot()
        throws
    {
        let observations = ProjectionAuthorityRecorder()
        let authority = HostAgentBackgroundProjectionAuthority(
            observer: { observations.append($0) }
        )
        let binding = authority.beginSession()
        try publishInitial(on: binding.sink, lastEventID: 1)
        let initialView = authority.snapshot()

        binding.sink.publishEvents(try suppressedBatch(
            hostID: "host-a",
            bootID: bootA,
            afterEventID: 1,
            eventID: 2
        ))
        binding.sink.publishEvents(try commandBatch(
            hostID: "host-a",
            bootID: bootA,
            afterEventID: 2,
            eventID: 3
        ))
        binding.sink.publishEvents(try upToDateResponse(
            hostID: "host-a",
            bootID: bootA,
            afterEventID: 3
        ))

        XCTAssertEqual(authority.snapshot(), initialView)
        XCTAssertEqual(observations.values.count, 2)
    }

    func testUnexpectedSnapshotChangedEventFailsClosedAndClearsProjection()
        throws
    {
        let observations = ProjectionAuthorityRecorder()
        let authority = HostAgentBackgroundProjectionAuthority(
            observer: { observations.append($0) }
        )
        let binding = authority.beginSession()
        try publishInitial(on: binding.sink, lastEventID: 1)

        binding.sink.publishEvents(try snapshotChangedBatch(
            hostID: "host-a",
            bootID: bootA,
            afterEventID: 1,
            eventID: 2
        ))

        XCTAssertEqual(
            authority.snapshot().phase,
            .failed(.invalidProjection)
        )
        XCTAssertEqual(authority.snapshot().snapshotStatus, .unavailable)
        XCTAssertEqual(observations.values.last?.phase,
                       .failed(.invalidProjection))
    }

    func testAuthoritativeResyncAtomicallyReplacesAvailableProjection()
        throws
    {
        let observations = ProjectionAuthorityRecorder()
        let authority = HostAgentBackgroundProjectionAuthority(
            observer: { observations.append($0) }
        )
        let binding = authority.beginSession()
        try publishInitial(on: binding.sink, lastEventID: 1)
        let trigger = try gapResponse(
            hostID: "host-a",
            bootID: bootA,
            afterEventID: 1,
            firstAvailableEventID: 3,
            latestEventID: 4
        )
        let refreshed = try snapshotResponse(
            hostID: "host-a",
            bootID: bootA,
            lastEventID: 4,
            localID: "987654321",
            registrationStatus: "degraded",
            observedAt: 20
        )

        binding.sink.publishResynchronizedSnapshot(
            refreshed,
            triggeringResponse: trigger
        )

        let view = authority.snapshot()
        XCTAssertEqual(view.generation, 3)
        XCTAssertEqual(view.rendezvousStatus, .offline)
        guard case .available(let projection) = view.phase else {
            return XCTFail("expected refreshed projection")
        }
        XCTAssertEqual(projection.payload.localID, "987654321")
        XCTAssertEqual(projection.snapshotEventID, 4)
        XCTAssertEqual(observations.values.count, 3)
    }

    func testNewSessionInvalidatesOldSinkAndCarriesPreviousIdentity() throws {
        let observations = ProjectionAuthorityRecorder()
        let authority = HostAgentBackgroundProjectionAuthority(
            observer: { observations.append($0) }
        )
        let oldBinding = authority.beginSession()
        let oldPeer = try peer(hostID: "host-a", bootID: bootA)
        oldBinding.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-a",
                bootID: bootA,
                lastEventID: 1,
                localID: "111",
                registrationStatus: "ready",
                observedAt: 10
            ),
            peerIdentity: oldPeer,
            transition: .firstObservation
        )
        oldBinding.sink.sessionDidTerminate(.disconnected)

        let replacement = authority.beginSession()
        XCTAssertEqual(replacement.previousPeerIdentity, oldPeer)
        oldBinding.sink.sessionDidTerminate(.timedOut)
        XCTAssertEqual(authority.snapshot().phase, .waitingForSnapshot)

        replacement.sink.resetForIdentityReplacement()
        XCTAssertEqual(authority.snapshot().phase, .replacingIdentity)
        let newPeer = try peer(hostID: "host-b", bootID: bootB)
        replacement.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-b",
                bootID: bootB,
                lastEventID: 1,
                localID: "222",
                registrationStatus: "pending",
                observedAt: 20
            ),
            peerIdentity: newPeer,
            transition: .replacedPrevious
        )

        guard case .available(let projection) = authority.snapshot().phase
        else { return XCTFail("expected replacement projection") }
        XCTAssertEqual(projection.peerIdentity, newPeer)
        XCTAssertEqual(authority.snapshot().rendezvousStatus, .checking)
    }

    func testReplacementWithoutPriorResetFailsClosed() throws {
        let authority = HostAgentBackgroundProjectionAuthority()
        let first = authority.beginSession()
        let oldPeer = try peer(hostID: "host-a", bootID: bootA)
        first.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-a",
                bootID: bootA,
                lastEventID: 1,
                observedAt: 10
            ),
            peerIdentity: oldPeer,
            transition: .firstObservation
        )
        first.sink.sessionDidTerminate(.disconnected)
        let replacement = authority.beginSession()
        let newPeer = try peer(hostID: "host-b", bootID: bootB)

        replacement.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-b",
                bootID: bootB,
                lastEventID: 1,
                observedAt: 20
            ),
            peerIdentity: newPeer,
            transition: .replacedPrevious
        )

        XCTAssertEqual(
            authority.snapshot().phase,
            .failed(.invalidProjection)
        )
    }

    func testSameIdentityReconnectRequiresUnchangedWithoutReset() throws {
        let authority = HostAgentBackgroundProjectionAuthority()
        let first = authority.beginSession()
        let existingPeer = try peer(hostID: "host-a", bootID: bootA)
        first.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-a",
                bootID: bootA,
                lastEventID: 1,
                observedAt: 10
            ),
            peerIdentity: existingPeer,
            transition: .firstObservation
        )
        first.sink.sessionDidTerminate(.disconnected)
        let reconnect = authority.beginSession()

        reconnect.sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-a",
                bootID: bootA,
                lastEventID: 2,
                observedAt: 20
            ),
            peerIdentity: existingPeer,
            transition: .unchanged
        )

        guard case .available(let projection) = authority.snapshot().phase
        else { return XCTFail("expected reconnected projection") }
        XCTAssertEqual(projection.peerIdentity, existingPeer)
        XCTAssertEqual(projection.snapshotEventID, 2)
    }

    func testForeignEventIdentityFailsClosed() throws {
        let authority = HostAgentBackgroundProjectionAuthority()
        let binding = authority.beginSession()
        try publishInitial(on: binding.sink, lastEventID: 1)

        binding.sink.publishEvents(try upToDateResponse(
            hostID: "host-b",
            bootID: bootB,
            afterEventID: 1
        ))

        XCTAssertEqual(
            authority.snapshot().phase,
            .failed(.invalidProjection)
        )
    }

    func testTerminalReasonClearsProjectionAndProducesConservativeHealth()
        throws
    {
        let authority = HostAgentBackgroundProjectionAuthority()
        let binding = authority.beginSession()
        try publishInitial(on: binding.sink, lastEventID: 1)

        binding.sink.sessionDidTerminate(.incompatible)

        let view = authority.snapshot()
        XCTAssertEqual(view.phase, .terminated(.incompatible))
        XCTAssertEqual(view.handshakeStatus, .incompatible)
        XCTAssertEqual(view.snapshotStatus, .unavailable)
        XCTAssertEqual(view.rendezvousStatus, .offline)
        binding.sink.sessionDidTerminate(.disconnected)
        XCTAssertEqual(authority.snapshot(), view)
    }

    func testSourceOwnsNoUIRegistrationMutationWireOrSecretStorage() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/CoreBridge/HostAgentBackgroundProjectionAuthority.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("HostAgentXPCSessionProjectionSink"))
        XCTAssertFalse(source.contains("AppKit"))
        XCTAssertFalse(source.contains("SwiftUI"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("HostAgentBackgroundServiceObserver"))
        XCTAssertFalse(source.contains("NSXPCConnection"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("HostAgentXPCWireCommandRequest"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("Keychain"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    private func publishInitial(
        on sink: HostAgentXPCSessionProjectionSink,
        lastEventID: UInt64
    ) throws {
        sink.publishInitialSnapshot(
            try snapshotResponse(
                hostID: "host-a",
                bootID: bootA,
                lastEventID: lastEventID,
                observedAt: 10
            ),
            peerIdentity: try peer(hostID: "host-a", bootID: bootA),
            transition: .firstObservation
        )
    }

    private func peer(hostID: String, bootID: String) throws
        -> HostAgentXPCSnapshotClientPeerIdentity
    {
        try HostAgentXPCSnapshotClientPeerIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func snapshotResponse(
        hostID: String,
        bootID: String,
        lastEventID: UInt64,
        localID: String = "123456789",
        registrationStatus: String = "ready",
        observedAt: UInt64
    ) throws -> HostAgentXPCWireSnapshotResponse {
        let request = try HostAgentXPCWireSnapshotRequest(
            requestID: "287fd5f2-98b7-4183-ac81-6973cef9a610",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            sentAtUnixMilliseconds: 11
        )
        let state = HostAgentSnapshotState()
        _ = state.publish(
            try coreSnapshot(
                hostID: hostID,
                localID: localID,
                registrationStatus: registrationStatus,
                observedAt: observedAt
            ),
            eventSequence: lastEventID,
            expectedHostInstanceID: hostID
        )
        return try HostAgentXPCWireSnapshotResponse.make(
            for: request,
            identity: try wireIdentity(hostID: hostID, bootID: bootID),
            state: state.snapshot(),
            sentAtUnixMilliseconds: 21
        )
    }

    private func upToDateResponse(
        hostID: String,
        bootID: String,
        afterEventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorResponse {
        let request = try eventRequest(
            hostID: hostID,
            bootID: bootID,
            afterEventID: afterEventID
        )
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try wireIdentity(hostID: hostID, bootID: bootID),
            replay: .upToDate(latestSequence: afterEventID),
            sentAtUnixMilliseconds: 22
        )
    }

    private func commandBatch(
        hostID: String,
        bootID: String,
        afterEventID: UInt64,
        eventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorResponse {
        try batchResponse(
            hostID: hostID,
            bootID: bootID,
            afterEventID: afterEventID,
            eventID: eventID,
            eventType: "commandResult",
            payload: [
                "commandId": "command-1",
                "status": "ok",
                "detail": "completed",
            ]
        )
    }

    private func snapshotChangedBatch(
        hostID: String,
        bootID: String,
        afterEventID: UInt64,
        eventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorResponse {
        try batchResponse(
            hostID: hostID,
            bootID: bootID,
            afterEventID: afterEventID,
            eventID: eventID,
            eventType: "sessionStarted",
            payload: [:]
        )
    }

    private func suppressedBatch(
        hostID: String,
        bootID: String,
        afterEventID: UInt64,
        eventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorResponse {
        try batchResponse(
            hostID: hostID,
            bootID: bootID,
            afterEventID: afterEventID,
            eventID: eventID,
            eventType: "mediaDiagnostic",
            payload: [:]
        )
    }

    private func batchResponse(
        hostID: String,
        bootID: String,
        afterEventID: UInt64,
        eventID: UInt64,
        eventType: String,
        payload: [String: Any]
    ) throws -> HostAgentXPCWireEventCursorResponse {
        let event = try XCTUnwrap(HostCoreEvent(rawJSON:
            JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "eventId": eventID,
                "eventType": eventType,
                "hostInstanceId": hostID,
                "sentAt": 1_700_000_000_000 as UInt64,
                "payload": payload,
            ])
        ))
        let request = try eventRequest(
            hostID: hostID,
            bootID: bootID,
            afterEventID: afterEventID
        )
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try wireIdentity(hostID: hostID, bootID: bootID),
            replay: .batch(
                records: [HostAgentEventRecord(
                    sequence: eventID,
                    event: event
                )],
                latestSequence: eventID,
                hasMore: false
            ),
            sentAtUnixMilliseconds: 22
        )
    }

    private func gapResponse(
        hostID: String,
        bootID: String,
        afterEventID: UInt64,
        firstAvailableEventID: UInt64,
        latestEventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorResponse {
        let request = try eventRequest(
            hostID: hostID,
            bootID: bootID,
            afterEventID: afterEventID
        )
        return try HostAgentXPCWireEventCursorResponse.make(
            for: request,
            identity: try wireIdentity(hostID: hostID, bootID: bootID),
            replay: .gap(
                firstAvailableSequence: firstAvailableEventID,
                latestSequence: latestEventID
            ),
            sentAtUnixMilliseconds: 22
        )
    }

    private func eventRequest(
        hostID: String,
        bootID: String,
        afterEventID: UInt64
    ) throws -> HostAgentXPCWireEventCursorRequest {
        try HostAgentXPCWireEventCursorRequest(
            requestID: "151db9a9-7dd3-4fea-93af-1b6c10840676",
            wireVersion: 1,
            hostInstanceID: hostID,
            agentBootID: bootID,
            afterEventID: afterEventID,
            maximumEventCount: 64,
            sentAtUnixMilliseconds: 12
        )
    }

    private func wireIdentity(hostID: String, bootID: String) throws
        -> HostAgentXPCWireAgentIdentity
    {
        try HostAgentXPCWireAgentIdentity(
            agentBuildID: "agent-build",
            hostInstanceID: hostID,
            agentBootID: bootID
        )
    }

    private func coreSnapshot(
        hostID: String,
        localID: String,
        registrationStatus: String,
        observedAt: UInt64
    ) throws -> HostCoreSnapshot {
        try HostCoreSnapshot(rawJSON: JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 5,
                "hostInstanceId": hostID,
                "hostState": "ready",
                "localId": localID,
                "registrationStatus": registrationStatus,
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
                "observedAt": observedAt,
            ]
        ))
    }
}

private final class ProjectionAuthorityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentBackgroundProjectionView] = []

    var values: [HostAgentBackgroundProjectionView] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: HostAgentBackgroundProjectionView) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
