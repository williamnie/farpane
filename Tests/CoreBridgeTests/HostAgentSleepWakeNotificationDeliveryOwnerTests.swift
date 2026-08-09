import Foundation
@testable import CoreBridge
import XCTest

final class HostAgentSleepWakeNotificationDeliveryOwnerTests: XCTestCase {
    func testDeliversOnlyExactSleepWakeCycles() {
        let recorder = SleepWakeNotificationRecorder()
        let owner = makeOwner(recorder: recorder)

        XCTAssertFalse(owner.deliver(.didWake))
        XCTAssertTrue(owner.deliver(.willSleep))
        XCTAssertFalse(owner.deliver(.willSleep))
        XCTAssertTrue(owner.deliver(.didWake))
        XCTAssertFalse(owner.deliver(.didWake))
        XCTAssertTrue(owner.deliver(.willSleep))
        XCTAssertTrue(owner.deliver(.didWake))

        XCTAssertEqual(
            recorder.events,
            [.willSleep, .didWake, .willSleep, .didWake]
        )
        XCTAssertEqual(owner.stateSnapshot(), .awake)
    }

    func testWillSleepFailureFailsClosed() {
        let recorder = SleepWakeNotificationRecorder(
            rejectedEvent: .willSleep
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertFalse(owner.deliver(.willSleep))
        XCTAssertFalse(owner.deliver(.didWake))
        XCTAssertEqual(owner.stateSnapshot(), .failed(.willSleep))
        XCTAssertEqual(recorder.events, [.willSleep])
    }

    func testDidWakeFailureFailsClosed() {
        let recorder = SleepWakeNotificationRecorder(
            rejectedEvent: .didWake
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertTrue(owner.deliver(.willSleep))
        XCTAssertFalse(owner.deliver(.didWake))
        XCTAssertFalse(owner.deliver(.willSleep))
        XCTAssertEqual(owner.stateSnapshot(), .failed(.didWake))
        XCTAssertEqual(recorder.events, [.willSleep, .didWake])
    }

    func testConcurrentNotificationIsRejectedWhileDeliveryIsInFlight() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = HostAgentSleepWakeNotificationDeliveryOwner(
            deliverWillSleep: {
                entered.signal()
                release.wait()
                return true
            },
            deliverDidWake: { true }
        )
        let finished = expectation(description: "will sleep delivered")

        DispatchQueue.global().async {
            XCTAssertTrue(owner.deliver(.willSleep))
            finished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        XCTAssertFalse(owner.deliver(.willSleep))
        XCTAssertFalse(owner.deliver(.didWake))
        release.signal()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(owner.stateSnapshot(), .sleeping)
    }

    func testCancellationClosesAdmissionAndDrainsAcceptedDelivery() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = HostAgentSleepWakeNotificationDeliveryOwner(
            deliverWillSleep: {
                entered.signal()
                release.wait()
                return true
            },
            deliverDidWake: { true }
        )
        let deliveryFinished = expectation(description: "delivery returned")
        let cancellationFinished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            _ = owner.deliver(.willSleep)
            deliveryFinished.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            owner.cancelAndWait()
            cancellationFinished.signal()
        }
        XCTAssertEqual(
            cancellationFinished.wait(timeout: .now() + 0.05),
            .timedOut
        )
        XCTAssertFalse(owner.deliver(.didWake))

        release.signal()
        wait(for: [deliveryFinished], timeout: 1)
        XCTAssertEqual(
            cancellationFinished.wait(timeout: .now() + 1),
            .success
        )
        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertFalse(owner.deliver(.willSleep))
    }

    func testCancellationBeforeNotificationIsTerminalAndIdempotent() {
        let recorder = SleepWakeNotificationRecorder()
        let owner = makeOwner(recorder: recorder)

        owner.cancelAndWait()
        owner.cancelAndWait()

        XCTAssertEqual(owner.stateSnapshot(), .cancelled)
        XCTAssertFalse(owner.deliver(.willSleep))
        XCTAssertFalse(owner.deliver(.didWake))
        XCTAssertEqual(recorder.events, [])
    }

    private func makeOwner(
        recorder: SleepWakeNotificationRecorder
    ) -> HostAgentSleepWakeNotificationDeliveryOwner {
        HostAgentSleepWakeNotificationDeliveryOwner(
            deliverWillSleep: {
                recorder.record(.willSleep)
            },
            deliverDidWake: {
                recorder.record(.didWake)
            }
        )
    }
}

private final class SleepWakeNotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let rejectedEvent: HostAgentSleepWakeNotificationEvent?
    private var eventStorage: [HostAgentSleepWakeNotificationEvent] = []

    init(rejectedEvent: HostAgentSleepWakeNotificationEvent? = nil) {
        self.rejectedEvent = rejectedEvent
    }

    var events: [HostAgentSleepWakeNotificationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return eventStorage
    }

    func record(_ event: HostAgentSleepWakeNotificationEvent) -> Bool {
        lock.lock()
        eventStorage.append(event)
        lock.unlock()
        return event != rejectedEvent
    }
}
