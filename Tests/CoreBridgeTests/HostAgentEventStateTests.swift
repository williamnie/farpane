@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentEventStateTests: XCTestCase {
    func testRejectsUnboundedConfiguration() {
        for (capacity, maximumEventBytes) in [
            (0, 4_096),
            (1_025, 4_096),
            (4, 255),
            (4, 65_537),
        ] {
            XCTAssertThrowsError(try HostAgentEventState(
                capacity: capacity,
                maximumEventBytes: maximumEventBytes
            )) { error in
                XCTAssertEqual(
                    error as? HostAgentEventStateConfigurationError,
                    .invalidLimits
                )
            }
        }
    }

    func testAcceptsEventsInArrivalOrderAndPinsHostInstance() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 4_096)
        let first = try event(id: 41, type: "snapshotChanged", host: "host-a")
        let second = try event(id: 42, type: "commandResult", host: "host-a")

        XCTAssertEqual(state.ingest(first), .accepted(sequence: 1))
        XCTAssertEqual(state.ingest(second), .accepted(sequence: 2))

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.hostInstanceID, "host-a")
        XCTAssertEqual(snapshot.firstAvailableSequence, 1)
        XCTAssertEqual(snapshot.latestSequence, 2)
        XCTAssertEqual(snapshot.evictedEventCount, 0)
        XCTAssertEqual(snapshot.rejectedEventCount, 0)
        XCTAssertEqual(snapshot.records.map(\.sequence), [1, 2])
        XCTAssertEqual(snapshot.records.map(\.event.eventId), [41, 42])
        XCTAssertEqual(snapshot.records.map(\.event.eventType), [
            "snapshotChanged",
            "commandResult",
        ])
        XCTAssertEqual(snapshot.records[0].event.rawJSON, first.rawJSON)
    }

    func testConsumeForwardsAcceptedEventOnceOutsideStateLock() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 4_096)
        let acceptedEvent = try event(id: 1, host: "host-a")
        var forwardedEventIDs: [UInt64] = []
        var visibleSequences: [UInt64] = []

        XCTAssertEqual(
            state.consume(acceptedEvent) { event, sequence in
                forwardedEventIDs.append(event.eventId)
                visibleSequences.append(sequence)
                XCTAssertEqual(state.snapshot().latestSequence, sequence)
            },
            .accepted(sequence: 1)
        )
        XCTAssertEqual(
            state.consume(acceptedEvent) { event, _ in
                forwardedEventIDs.append(event.eventId)
            },
            .rejected(.duplicateEventID)
        )

        XCTAssertEqual(forwardedEventIDs, [1])
        XCTAssertEqual(visibleSequences, [1])
    }

    func testEvictsOldestRecordAndRejectsRetainedDuplicate() throws {
        let state = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)

        XCTAssertEqual(
            state.ingest(try event(id: 1, host: "host-a")),
            .accepted(sequence: 1)
        )
        XCTAssertEqual(
            state.ingest(try event(id: 2, host: "host-a")),
            .accepted(sequence: 2)
        )
        XCTAssertEqual(
            state.ingest(try event(id: 3, host: "host-a")),
            .accepted(sequence: 3)
        )
        XCTAssertEqual(
            state.ingest(try event(id: 2, host: "host-a")),
            .rejected(.duplicateEventID)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.firstAvailableSequence, 2)
        XCTAssertEqual(snapshot.latestSequence, 3)
        XCTAssertEqual(snapshot.records.map(\.event.eventId), [2, 3])
        XCTAssertEqual(snapshot.evictedEventCount, 1)
        XCTAssertEqual(snapshot.rejectedEventCount, 1)
    }

    func testAcceptsUniqueOutOfOrderCoreEventIDs() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 4_096)

        XCTAssertEqual(
            state.ingest(try event(id: 10, host: "host-a")),
            .accepted(sequence: 1)
        )
        XCTAssertEqual(
            state.ingest(try event(id: 9, host: "host-a")),
            .accepted(sequence: 2)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.records.map(\.sequence), [1, 2])
        XCTAssertEqual(snapshot.records.map(\.event.eventId), [10, 9])
    }

    func testRejectsForeignHostWithoutMutatingAcceptedWindow() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 4_096)
        XCTAssertEqual(
            state.ingest(try event(id: 1, host: "host-a")),
            .accepted(sequence: 1)
        )

        XCTAssertEqual(
            state.ingest(try event(id: 2, host: "host-b")),
            .rejected(.foreignHostInstance)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.hostInstanceID, "host-a")
        XCTAssertEqual(snapshot.latestSequence, 1)
        XCTAssertEqual(snapshot.records.map(\.event.eventId), [1])
        XCTAssertEqual(snapshot.rejectedEventCount, 1)
    }

    func testRejectsInvalidAndOversizedEventsBeforePinningHost() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 512)

        XCTAssertEqual(
            state.ingest(try event(id: 0, host: "host-a")),
            .rejected(.invalidEventID)
        )
        XCTAssertEqual(
            state.ingest(try event(
                id: 1,
                host: "host-a",
                payload: String(repeating: "x", count: 1_024)
            )),
            .rejected(.oversizedEnvelope)
        )
        XCTAssertEqual(
            state.ingest(try event(id: 1, host: "host-b")),
            .accepted(sequence: 1)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.hostInstanceID, "host-b")
        XCTAssertEqual(snapshot.latestSequence, 1)
        XCTAssertEqual(snapshot.rejectedEventCount, 2)
    }

    func testConcurrentIngestProducesContiguousLocalSequence() throws {
        let state = try HostAgentEventState(capacity: 128, maximumEventBytes: 4_096)
        let events = try (1...100).map {
            try event(id: UInt64($0), host: "host-a")
        }
        let group = DispatchGroup()

        for event in events {
            group.enter()
            DispatchQueue.global().async {
                _ = state.ingest(event)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.records.count, 100)
        XCTAssertEqual(snapshot.records.map(\.sequence), Array(1...100).map(UInt64.init))
        XCTAssertEqual(
            Set(snapshot.records.map(\.event.eventId)),
            Set((1...100).map(UInt64.init))
        )
        XCTAssertEqual(snapshot.rejectedEventCount, 0)
        XCTAssertEqual(snapshot.evictedEventCount, 0)
    }

    private func event(
        id: UInt64,
        type: String = "snapshotChanged",
        host: String,
        payload: String = "ok"
    ) throws -> HostCoreEvent {
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "eventId": id,
            "eventType": type,
            "hostInstanceId": host,
            "sentAt": 1_700_000_000_000 as UInt64,
            "payload": ["value": payload],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return try XCTUnwrap(HostCoreEvent(rawJSON: data))
    }
}
