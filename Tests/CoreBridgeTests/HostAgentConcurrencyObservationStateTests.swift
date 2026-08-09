@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentConcurrencyObservationStateTests: XCTestCase {
    func testBuffersExactSessionEdgesAndDrainsInSourceOrder() throws {
        let state = HostAgentConcurrencyObservationState(capacity: 4)

        XCTAssertTrue(state.observe(event: try event(type: "sessionStarted")))
        XCTAssertFalse(state.observe(event: try event(type: "mediaControl")))
        XCTAssertTrue(state.observe(event: try event(type: "sessionEnded")))
        XCTAssertEqual(state.snapshot(), .init(
            acceptedObservations: 2,
            deliveredObservations: 0,
            pendingObservations: 2,
            lastSourceGeneration: 2,
            bound: false,
            failed: false,
            cancelled: false
        ))

        let recorder = LockedConcurrencyObservations()
        XCTAssertTrue(state.bind { recorder.append($0) })
        let delivered = recorder.snapshot()
        XCTAssertEqual(delivered.map(\.state), [
            .inboundMediaActive,
            .disconnected,
        ])
        XCTAssertEqual(delivered.map(\.sourceGeneration), [1, 2])
        XCTAssertTrue(delivered.allSatisfy {
            $0.hostInstanceID == "host-a"
        })
        XCTAssertEqual(state.snapshot().deliveredObservations, 2)
        XCTAssertEqual(state.snapshot().pendingObservations, 0)
        XCTAssertFalse(state.bind { _ in })
    }

    func testClassifiesOnlyCoherentAcceptedSnapshotStates() throws {
        let observationState = HostAgentConcurrencyObservationState()
        let snapshotState = HostAgentSnapshotState()
        let recorder = LockedConcurrencyObservations()
        XCTAssertTrue(observationState.bind { recorder.append($0) })

        XCTAssertFalse(observationState.observe(snapshot: snapshotState.snapshot()))
        _ = snapshotState.publish(
            try coreSnapshot(observedAt: 100),
            eventSequence: 1,
            expectedHostInstanceID: "host-a"
        )
        XCTAssertTrue(observationState.observe(snapshot: snapshotState.snapshot()))
        _ = snapshotState.publish(
            try coreSnapshot(observedAt: 101, active: true),
            eventSequence: 2,
            expectedHostInstanceID: "host-a"
        )
        XCTAssertTrue(observationState.observe(snapshot: snapshotState.snapshot()))
        _ = snapshotState.publish(
            try coreSnapshot(
                observedAt: 102,
                hostState: "starting",
                registrationStatus: "pending"
            ),
            eventSequence: 3,
            expectedHostInstanceID: "host-a"
        )
        XCTAssertTrue(observationState.observe(snapshot: snapshotState.snapshot()))
        _ = snapshotState.publish(
            try coreSnapshot(
                observedAt: 103,
                authenticatedConnectionCount: 1
            ),
            eventSequence: 4,
            expectedHostInstanceID: "host-a"
        )
        XCTAssertFalse(observationState.observe(snapshot: snapshotState.snapshot()))

        let delivered = recorder.snapshot()
        XCTAssertEqual(delivered.map(\.state), [
            .readyZeroInbound,
            .inboundMediaActive,
            .disconnected,
        ])
        XCTAssertEqual(delivered.map(\.sourceGeneration), [1, 2, 3])
    }

    func testOverflowFailsClosedAndCancellationDoesNotBecomeFailure() throws {
        let overflow = HostAgentConcurrencyObservationState(capacity: 2)
        XCTAssertTrue(overflow.observe(event: try event(type: "sessionStarted")))
        XCTAssertTrue(overflow.observe(event: try event(type: "sessionEnded")))
        XCTAssertFalse(overflow.observe(event: try event(type: "sessionStarted")))
        XCTAssertTrue(overflow.snapshot().failed)
        XCTAssertEqual(overflow.snapshot().pendingObservations, 0)
        XCTAssertFalse(overflow.bind { _ in })

        let cancelled = HostAgentConcurrencyObservationState()
        cancelled.cancelAndWait()
        XCTAssertFalse(cancelled.observe(event: try event(type: "sessionStarted")))
        XCTAssertTrue(cancelled.snapshot().cancelled)
        XCTAssertFalse(cancelled.snapshot().failed)
    }

    private func event(type: String) throws -> HostCoreEvent {
        let document: [String: Any] = [
            "schemaVersion": 1,
            "eventId": 1,
            "eventType": type,
            "hostInstanceId": "host-a",
            "sentAt": 1_700_000_000_000 as UInt64,
            "payload": [:],
        ]
        let data = try JSONSerialization.data(withJSONObject: document)
        return try XCTUnwrap(HostCoreEvent(rawJSON: data))
    }

    private func coreSnapshot(
        observedAt: UInt64,
        hostState: String = "ready",
        registrationStatus: String = "ready",
        authenticatedConnectionCount: UInt64 = 0,
        active: Bool = false
    ) throws -> HostCoreSnapshot {
        let activeSession: Any = active ? [
            "connectionId": "host-a:9",
            "remoteId": "remote-id",
            "remoteName": "Remote Mac",
            "remotePlatform": "macOS",
            "remoteMetadataTrust": "untrusted",
            "startedAt": 1_700_000_000_000 as UInt64,
            "initialCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "activeCapabilities": [
                "viewDisplay", "controlKeyboardMouse",
            ],
            "inputAvailability": "available",
            "inputUnavailableReason": NSNull(),
        ] : NSNull()
        let document: [String: Any] = [
            "schemaVersion": 8,
            "hostInstanceId": "host-a",
            "hostState": hostState,
            "localId": "123456789",
            "authenticatedConnectionCount": active
                ? 1 : authenticatedConnectionCount,
            "sessionAvailability": "available",
            "sessionUnavailableReason": NSNull(),
            "registrationStatus": registrationStatus,
            "recoveryEpoch": 0,
            "recoveryStatus": "running",
            "pendingApproval": NSNull(),
            "activeSession": activeSession,
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
        return try HostCoreSnapshot(
            rawJSON: JSONSerialization.data(withJSONObject: document)
        )
    }
}

private final class LockedConcurrencyObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HostAgentConcurrencyObservation] = []

    func append(_ value: HostAgentConcurrencyObservation) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [HostAgentConcurrencyObservation] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
