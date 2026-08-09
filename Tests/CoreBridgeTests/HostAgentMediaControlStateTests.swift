@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentMediaControlStateTests: XCTestCase {
    func testAcceptsOrderedSingleRouteLifecycle() throws {
        let state = HostAgentMediaControlState()
        var delivered: [HostMediaControl.Command] = []

        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 1, command: "startCapture"),
                eventSequence: 1,
                onAccepted: { delivered.append($0.command) }
            ),
            .accepted(command: .startCapture, eventSequence: 1)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 2, command: "reconfigure", includeConfiguration: true),
                eventSequence: 2,
                onAccepted: { delivered.append($0.command) }
            ),
            .accepted(command: .reconfigure, eventSequence: 2)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 3, command: "requestIdr"),
                eventSequence: 3,
                onAccepted: { delivered.append($0.command) }
            ),
            .accepted(command: .requestIdr, eventSequence: 3)
        )

        var snapshot = state.snapshot()
        XCTAssertNil(snapshot.pendingRoute)
        XCTAssertEqual(snapshot.activeRoute, route())
        XCTAssertEqual(snapshot.latestAcceptedEventSequence, 3)
        XCTAssertEqual(snapshot.acceptedControlCount, 3)
        XCTAssertEqual(snapshot.rejectedControlCount, 0)

        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 4,
                    command: "stopCapture",
                    includeDisplayRevision: false
                ),
                eventSequence: 4,
                onAccepted: { delivered.append($0.command) }
            ),
            .accepted(command: .stopCapture, eventSequence: 4)
        )
        snapshot = state.snapshot()
        XCTAssertNil(snapshot.pendingRoute)
        XCTAssertNil(snapshot.activeRoute)
        XCTAssertEqual(snapshot.latestAcceptedEventSequence, 4)
        XCTAssertEqual(snapshot.acceptedControlCount, 4)
        XCTAssertEqual(delivered, [
            .startCapture,
            .reconfigure,
            .requestIdr,
            .stopCapture,
        ])
    }

    func testRejectsMalformedOutOfOrderMismatchedAndReplayedControls() throws {
        let state = HostAgentMediaControlState()
        var delivered = 0
        let deliver: (HostMediaControl) -> Void = { _ in delivered += 1 }

        XCTAssertEqual(
            state.consume(
                try malformedControlEvent(id: 1),
                eventSequence: 1,
                onAccepted: deliver
            ),
            .rejected(.invalidControl)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 2, command: "reconfigure", includeConfiguration: true),
                eventSequence: 2,
                onAccepted: deliver
            ),
            .rejected(.missingRouteStart)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 3, command: "startCapture"),
                eventSequence: 3,
                onAccepted: deliver
            ),
            .accepted(command: .startCapture, eventSequence: 3)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 4, command: "startCapture"),
                eventSequence: 4,
                onAccepted: deliver
            ),
            .rejected(.staleRoute)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 5,
                    command: "reconfigure",
                    connectionEpoch: 12,
                    codecEpoch: 22,
                    includeConfiguration: true
                ),
                eventSequence: 5,
                onAccepted: deliver
            ),
            .rejected(.routeMismatch)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 6, command: "reconfigure", includeConfiguration: true),
                eventSequence: 6,
                onAccepted: deliver
            ),
            .accepted(command: .reconfigure, eventSequence: 6)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 7,
                    command: "requestIdr",
                    displayRevision: 4
                ),
                eventSequence: 7,
                onAccepted: deliver
            ),
            .rejected(.routeMismatch)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 8,
                    command: "stopCapture",
                    includeDisplayRevision: false
                ),
                eventSequence: 8,
                onAccepted: deliver
            ),
            .accepted(command: .stopCapture, eventSequence: 8)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 9, command: "startCapture"),
                eventSequence: 9,
                onAccepted: deliver
            ),
            .rejected(.staleRoute)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 10,
                    command: "startCapture",
                    connectionEpoch: 13,
                    codecEpoch: 23
                ),
                eventSequence: 6,
                onAccepted: deliver
            ),
            .rejected(.staleEventSequence)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(delivered, 3)
        XCTAssertEqual(snapshot.acceptedControlCount, 3)
        XCTAssertEqual(snapshot.rejectedControlCount, 7)
        XCTAssertEqual(snapshot.latestAcceptedEventSequence, 8)
        XCTAssertNil(snapshot.activeRoute)
    }

    func testIgnoresNonMediaEventsWithoutAdvancingAuthority() throws {
        let state = HostAgentMediaControlState()
        let event = try event(id: 1, type: "snapshotChanged", payload: [:])

        XCTAssertEqual(
            state.consume(event, eventSequence: 1, onAccepted: { _ in
                XCTFail("non-media event must not be delivered")
            }),
            .ignored
        )
        XCTAssertEqual(state.snapshot().latestAcceptedEventSequence, 0)
        XCTAssertEqual(state.snapshot().acceptedControlCount, 0)
        XCTAssertEqual(state.snapshot().rejectedControlCount, 0)
    }

    func testRejectsIncompleteAndFractionalRouteFieldsAsInvalidControl() throws {
        let state = HostAgentMediaControlState()
        let deliver: (HostMediaControl) -> Void = { _ in }

        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 1,
                    command: "startCapture",
                    includeDisplayRevision: false
                ),
                eventSequence: 1,
                onAccepted: deliver
            ),
            .rejected(.invalidControl)
        )
        XCTAssertEqual(
            state.consume(
                try event(
                    id: 2,
                    type: "mediaControl",
                    payload: [
                        "command": "startCapture",
                        "connectionEpoch": true,
                        "codecEpoch": 21,
                        "displayId": 0,
                        "displayRevision": 3,
                    ]
                ),
                eventSequence: 2,
                onAccepted: deliver
            ),
            .rejected(.invalidControl)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(id: 3, command: "startCapture"),
                eventSequence: 3,
                onAccepted: deliver
            ),
            .accepted(command: .startCapture, eventSequence: 3)
        )
        let fractionalPayload: [String: Any] = [
            "command": "reconfigure",
            "connectionEpoch": 11,
            "codecEpoch": 21,
            "displayId": 0,
            "displayRevision": 3,
            "codec": "h264",
            "width": 1_920.5,
            "height": 1_080,
            "fps": 30,
            "bitrate": 4_000_000,
        ]
        let fractional = try event(
            id: 4,
            type: "mediaControl",
            payload: fractionalPayload
        )
        XCTAssertEqual(
            state.consume(
                fractional,
                eventSequence: 4,
                onAccepted: deliver
            ),
            .rejected(.invalidControl)
        )

        let snapshot = state.snapshot()
        XCTAssertEqual(snapshot.pendingRoute, route())
        XCTAssertNil(snapshot.activeRoute)
        XCTAssertEqual(snapshot.acceptedControlCount, 1)
        XCTAssertEqual(snapshot.rejectedControlCount, 3)
    }

    func testRequiresExactDisplayProvenanceAcrossStartAndReconfigure() throws {
        let state = HostAgentMediaControlState()
        let provenance: [String: Any] = [
            "displayReconfigureGeneration": 4,
            "previousDisplayRevision": 2,
            "previousConnectionEpoch": 10,
            "previousCodecEpoch": 20,
        ]
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 1,
                    command: "startCapture",
                    displayReconfigure: provenance
                ),
                eventSequence: 1,
                onAccepted: { _ in }
            ),
            .accepted(command: .startCapture, eventSequence: 1)
        )
        var mismatched = provenance
        mismatched["displayReconfigureGeneration"] = 5
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 2,
                    command: "reconfigure",
                    includeConfiguration: true,
                    displayReconfigure: mismatched
                ),
                eventSequence: 2,
                onAccepted: { _ in }
            ),
            .rejected(.displayProvenanceMismatch)
        )
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 3,
                    command: "reconfigure",
                    includeConfiguration: true,
                    displayReconfigure: provenance
                ),
                eventSequence: 3,
                onAccepted: { _ in }
            ),
            .accepted(command: .reconfigure, eventSequence: 3)
        )
        XCTAssertNil(state.snapshot().pendingDisplayReconfigure)
    }

    func testCancelWaitsForInFlightActionAndRejectsFutureControls() throws {
        let state = HostAgentMediaControlState()
        let actionEntered = DispatchSemaphore(value: 0)
        let releaseAction = DispatchSemaphore(value: 0)
        let consumeReturned = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let start = try controlEvent(id: 1, command: "startCapture")

        DispatchQueue.global().async {
            _ = state.consume(start, eventSequence: 1) { _ in
                actionEntered.signal()
                _ = releaseAction.wait(timeout: .now() + 2)
            }
            consumeReturned.signal()
        }
        XCTAssertEqual(actionEntered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            state.cancelAndWait()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(
            state.consume(
                try controlEvent(
                    id: 2,
                    command: "startCapture",
                    connectionEpoch: 12,
                    codecEpoch: 22
                ),
                eventSequence: 2,
                onAccepted: { _ in XCTFail("cancelled state must reject") }
            ),
            .rejected(.cancelled)
        )
        releaseAction.signal()
        XCTAssertEqual(consumeReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)

        let snapshot = state.snapshot()
        XCTAssertTrue(snapshot.cancelled)
        XCTAssertNil(snapshot.pendingRoute)
        XCTAssertNil(snapshot.activeRoute)
        XCTAssertEqual(snapshot.acceptedControlCount, 1)
        XCTAssertEqual(snapshot.rejectedControlCount, 1)
        state.cancelAndWait()
    }

    private func route(
        connectionEpoch: UInt64 = 11,
        codecEpoch: UInt64 = 21,
        displayRevision: UInt64 = 3
    ) -> HostAgentMediaRoute {
        HostAgentMediaRoute(
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: 0,
            displayRevision: displayRevision
        )
    }

    private func controlEvent(
        id: UInt64,
        command: String,
        connectionEpoch: UInt64 = 11,
        codecEpoch: UInt64 = 21,
        displayRevision: UInt64 = 3,
        includeDisplayRevision: Bool = true,
        includeConfiguration: Bool = false,
        displayReconfigure: [String: Any]? = nil
    ) throws -> HostCoreEvent {
        var payload: [String: Any] = [
            "command": command,
            "connectionEpoch": connectionEpoch,
            "codecEpoch": codecEpoch,
            "displayId": 0,
        ]
        if includeDisplayRevision {
            payload["displayRevision"] = displayRevision
        }
        if includeConfiguration {
            payload["codec"] = "h264"
            payload["width"] = 1_920
            payload["height"] = 1_080
            payload["fps"] = 30
            payload["bitrate"] = 4_000_000
        }
        if let displayReconfigure {
            payload["displayReconfigure"] = displayReconfigure
        }
        return try event(id: id, type: "mediaControl", payload: payload)
    }

    private func malformedControlEvent(id: UInt64) throws -> HostCoreEvent {
        try event(id: id, type: "mediaControl", payload: ["command": "startCapture"])
    }

    private func event(
        id: UInt64,
        type: String,
        payload: [String: Any]
    ) throws -> HostCoreEvent {
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "eventId": id,
            "eventType": type,
            "hostInstanceId": "host-a",
            "sentAt": 1_700_000_000_000 as UInt64,
            "payload": payload,
        ]
        return try XCTUnwrap(HostCoreEvent(
            rawJSON: JSONSerialization.data(withJSONObject: envelope)
        ))
    }
}
