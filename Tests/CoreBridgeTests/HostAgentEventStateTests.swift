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
        let second = try event(id: 42, type: "sessionStarted", host: "host-a")

        XCTAssertEqual(state.ingest(first), .accepted(sequence: 1))
        XCTAssertEqual(state.ingest(second), .accepted(sequence: 2))

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.hostInstanceID, "host-a")
        XCTAssertEqual(snapshot.firstAvailableSequence, 1)
        XCTAssertEqual(snapshot.latestSequence, 2)
        XCTAssertEqual(snapshot.evictedEventCount, 0)
        XCTAssertEqual(snapshot.rejectedEventCount, 0)
        XCTAssertEqual(snapshot.records.map(\.sequence), [1, 2])
        XCTAssertEqual(coreEvents(snapshot.records).map(\.eventId), [41, 42])
        XCTAssertEqual(coreEvents(snapshot.records).map(\.eventType), [
            "snapshotChanged",
            "sessionStarted",
        ])
        XCTAssertEqual(coreEvents(snapshot.records)[0].rawJSON, first.rawJSON)
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
        XCTAssertEqual(coreEvents(snapshot.records).map(\.eventId), [2, 3])
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
        XCTAssertEqual(coreEvents(snapshot.records).map(\.eventId), [10, 9])
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
        XCTAssertEqual(coreEvents(snapshot.records).map(\.eventId), [1])
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
            Set(coreEvents(snapshot.records).map(\.eventId)),
            Set((1...100).map(UInt64.init))
        )
        XCTAssertEqual(snapshot.rejectedEventCount, 0)
        XCTAssertEqual(snapshot.evictedEventCount, 0)
    }

    func testReplayReturnsAtomicBoundedContiguousBatches() throws {
        let state = try HostAgentEventState(capacity: 4, maximumEventBytes: 4_096)

        assertUpToDate(
            try state.replay(afterSequence: 0, limit: 2),
            latestSequence: 0
        )
        for eventID in 1...3 {
            XCTAssertEqual(
                state.ingest(try event(id: UInt64(eventID), host: "host-a")),
                .accepted(sequence: UInt64(eventID))
            )
        }

        assertBatch(
            try state.replay(afterSequence: 0, limit: 2),
            sequences: [1, 2],
            sourceEventIDs: [1, 2],
            latestSequence: 3,
            hasMore: true
        )
        assertBatch(
            try state.replay(afterSequence: 2, limit: 2),
            sequences: [3],
            sourceEventIDs: [3],
            latestSequence: 3,
            hasMore: false
        )
        assertUpToDate(
            try state.replay(afterSequence: 3, limit: 2),
            latestSequence: 3
        )
    }

    func testReplayDistinguishesEvictionGapFromExactWindowBoundary() throws {
        let state = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)
        for eventID in 1...3 {
            _ = state.ingest(try event(id: UInt64(eventID), host: "host-a"))
        }

        guard case .gap(let firstAvailable, let latest) =
            try state.replay(afterSequence: 0, limit: 2)
        else { return XCTFail("expected replay gap") }
        XCTAssertEqual(firstAvailable, 2)
        XCTAssertEqual(latest, 3)

        assertBatch(
            try state.replay(afterSequence: 1, limit: 2),
            sequences: [2, 3],
            sourceEventIDs: [2, 3],
            latestSequence: 3,
            hasMore: false
        )
    }

    func testReplayRejectsFutureCursorAndInvalidLimits() throws {
        let state = try HostAgentEventState(capacity: 2, maximumEventBytes: 4_096)
        _ = state.ingest(try event(id: 1, host: "host-a"))

        guard case .invalidCursor(let latest) =
            try state.replay(afterSequence: 2, limit: 1)
        else { return XCTFail("expected invalid future cursor") }
        XCTAssertEqual(latest, 1)

        for invalidLimit in [0, 257] {
            XCTAssertThrowsError(try state.replay(
                afterSequence: 0,
                limit: invalidLimit
            )) { error in
                XCTAssertEqual(
                    error as? HostAgentEventReplayError,
                    .invalidLimit
                )
            }
        }
    }

    private func assertUpToDate(
        _ result: HostAgentEventReplayResult,
        latestSequence: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .upToDate(let actualLatest) = result else {
            return XCTFail("expected up-to-date replay", file: file, line: line)
        }
        XCTAssertEqual(actualLatest, latestSequence, file: file, line: line)
    }

    private func assertBatch(
        _ result: HostAgentEventReplayResult,
        sequences: [UInt64],
        sourceEventIDs: [UInt64],
        latestSequence: UInt64,
        hasMore: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .batch(let records, let latest, let actualHasMore) = result
        else { return XCTFail("expected replay batch", file: file, line: line) }
        XCTAssertEqual(records.map(\.sequence), sequences, file: file, line: line)
        XCTAssertEqual(
            coreEvents(records).map(\.eventId),
            sourceEventIDs,
            file: file,
            line: line
        )
        XCTAssertEqual(latest, latestSequence, file: file, line: line)
        XCTAssertEqual(actualHasMore, hasMore, file: file, line: line)
    }

    private func coreEvents(
        _ records: [HostAgentEventRecord]
    ) -> [HostCoreEvent] {
        records.compactMap { record in
            guard case .core(let event) = record.payload else { return nil }
            return event
        }
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
