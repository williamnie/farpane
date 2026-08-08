@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentMediaControlDeliveryGateTests: XCTestCase {
    func testBuffersStartupControlsThenDrainsInOrderBeforeActiveDelivery() throws {
        let gate = HostAgentMediaControlDeliveryGate()
        let start = try control(command: "startCapture", epoch: 11)
        let reconfigure = try control(
            command: "reconfigure",
            epoch: 11,
            includeConfiguration: true
        )
        let recorder = MediaControlDeliveryRecorder()

        XCTAssertEqual(gate.submit(start), .buffered)
        XCTAssertEqual(gate.submit(reconfigure), .buffered)
        XCTAssertTrue(recorder.commands.isEmpty)
        XCTAssertEqual(gate.snapshot().bufferedControlCount, 2)

        XCTAssertTrue(gate.activate { recorder.record($0) })
        XCTAssertEqual(recorder.commands, [.startCapture, .reconfigure])
        XCTAssertEqual(
            gate.submit(try control(command: "requestIdr", epoch: 11)),
            .delivered
        )
        XCTAssertEqual(recorder.commands, [
            .startCapture,
            .reconfigure,
            .requestIdr,
        ])
        let snapshot = gate.snapshot()
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertEqual(snapshot.bufferedControlCount, 0)
        XCTAssertEqual(snapshot.deliveredControlCount, 3)
        XCTAssertEqual(snapshot.rejectedControlCount, 0)
        XCTAssertFalse(snapshot.deliveryInFlight)
    }

    func testStartupOverflowDropsBufferedControlsAndPreventsActivation() throws {
        let gate = HostAgentMediaControlDeliveryGate()
        let recorder = MediaControlDeliveryRecorder()

        for offset in 0..<HostAgentMediaControlDeliveryGate.maximumBufferedControls {
            XCTAssertEqual(
                gate.submit(try control(
                    command: "startCapture",
                    epoch: UInt64(11 + offset)
                )),
                .buffered
            )
        }
        XCTAssertEqual(
            gate.submit(try control(command: "startCapture", epoch: 100)),
            .rejected
        )

        XCTAssertFalse(gate.activate { recorder.record($0) })
        XCTAssertEqual(
            gate.submit(try control(command: "startCapture", epoch: 101)),
            .rejected
        )
        let snapshot = gate.snapshot()
        XCTAssertEqual(snapshot.status, .overflowed)
        XCTAssertEqual(snapshot.bufferedControlCount, 0)
        XCTAssertEqual(snapshot.deliveredControlCount, 0)
        XCTAssertEqual(snapshot.rejectedControlCount, 2)
        XCTAssertEqual(recorder.commands.count, 0)
    }

    func testCancelWaitsForActiveDeliveryAndRejectsFutureControls() throws {
        let gate = HostAgentMediaControlDeliveryGate()
        let deliveryEntered = DispatchSemaphore(value: 0)
        let releaseDelivery = DispatchSemaphore(value: 0)
        let submitReturned = DispatchSemaphore(value: 0)
        let cancelReturned = DispatchSemaphore(value: 0)
        let start = try control(command: "startCapture", epoch: 11)
        XCTAssertTrue(gate.activate { _ in
            deliveryEntered.signal()
            _ = releaseDelivery.wait(timeout: .now() + 2)
            submitReturned.signal()
        })

        DispatchQueue.global().async {
            _ = gate.submit(start)
        }
        XCTAssertEqual(deliveryEntered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            gate.cancelAndWait()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(
            gate.submit(try control(command: "startCapture", epoch: 12)),
            .rejected
        )
        releaseDelivery.signal()
        XCTAssertEqual(submitReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)

        let snapshot = gate.snapshot()
        XCTAssertEqual(snapshot.status, .cancelled)
        XCTAssertEqual(snapshot.deliveredControlCount, 1)
        XCTAssertEqual(snapshot.rejectedControlCount, 1)
        XCTAssertFalse(snapshot.deliveryInFlight)
        gate.cancelAndWait()
    }

    func testCancelBeforeActivationDropsBufferedControls() throws {
        let gate = HostAgentMediaControlDeliveryGate()
        let recorder = MediaControlDeliveryRecorder()
        XCTAssertEqual(
            gate.submit(try control(command: "startCapture", epoch: 11)),
            .buffered
        )

        gate.cancelAndWait()

        XCTAssertFalse(gate.activate { recorder.record($0) })
        XCTAssertEqual(recorder.commands.count, 0)
        XCTAssertEqual(gate.snapshot().status, .cancelled)
        XCTAssertEqual(gate.snapshot().bufferedControlCount, 0)
    }

    private func control(
        command: String,
        epoch: UInt64,
        includeConfiguration: Bool = false
    ) throws -> HostMediaControl {
        var payload: [String: Any] = [
            "command": command,
            "connectionEpoch": epoch,
            "codecEpoch": epoch + 10,
            "displayId": 0,
            "displayRevision": 3,
        ]
        if includeConfiguration {
            payload["codec"] = "h264"
            payload["width"] = 1_920
            payload["height"] = 1_080
            payload["fps"] = 30
            payload["bitrate"] = 4_000_000
        }
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "eventId": epoch,
            "eventType": "mediaControl",
            "hostInstanceId": "host-a",
            "sentAt": 1_700_000_000_000 as UInt64,
            "payload": payload,
        ]
        let event = try XCTUnwrap(HostCoreEvent(
            rawJSON: JSONSerialization.data(withJSONObject: envelope)
        ))
        return try XCTUnwrap(event.mediaControl)
    }
}

private final class MediaControlDeliveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCommands: [HostMediaControl.Command] = []

    var commands: [HostMediaControl.Command] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCommands
    }

    func record(_ control: HostMediaControl) {
        lock.lock()
        recordedCommands.append(control.command)
        lock.unlock()
    }
}
