import CoreBridge
import ViewerInput
import XCTest

final class ExclusiveKeyboardEventDispatcherTests: XCTestCase {
    func testEnqueueReturnsWithoutWaitingForBlockedCoreSend() {
        let sendStarted = expectation(description: "send started")
        let enqueueReturned = expectation(description: "enqueue returned")
        let sendFinished = expectation(description: "send finished")
        let allowSendToFinish = DispatchSemaphore(value: 0)
        let dispatcher = ExclusiveKeyboardEventDispatcher(
            send: { _ in
                sendStarted.fulfill()
                allowSendToFinish.wait()
                sendFinished.fulfill()
                return 0
            },
            recordResult: { _, _ in }
        )

        DispatchQueue.global().async {
            dispatcher.enqueue(CoreKeyEvent(key: .physical(45), isDown: true))
            enqueueReturned.fulfill()
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [enqueueReturned, sendStarted], timeout: 1),
            .completed
        )
        allowSendToFinish.signal()
        wait(for: [sendFinished], timeout: 1)
    }

    func testSerializesKeyTransitionsInAdmissionOrder() {
        let recordedAllEvents = expectation(description: "recorded all events")
        recordedAllEvents.expectedFulfillmentCount = 4
        let recorder = KeyEventRecorder()
        let dispatcher = ExclusiveKeyboardEventDispatcher(
            send: { event in
                recorder.append(event)
                return 0
            },
            recordResult: { _, _ in recordedAllEvents.fulfill() }
        )

        dispatcher.enqueue(CoreKeyEvent(key: .physical(55), isDown: true))
        dispatcher.enqueue(CoreKeyEvent(key: .physical(45), isDown: true))
        dispatcher.enqueue(CoreKeyEvent(key: .physical(45), isDown: false))
        dispatcher.enqueue(CoreKeyEvent(key: .physical(55), isDown: false))

        wait(for: [recordedAllEvents], timeout: 1)
        XCTAssertEqual(
            recorder.snapshot(),
            [
                KeyTransition(key: .physical(55), isDown: true),
                KeyTransition(key: .physical(45), isDown: true),
                KeyTransition(key: .physical(45), isDown: false),
                KeyTransition(key: .physical(55), isDown: false),
            ]
        )
    }
}

private struct KeyTransition: Equatable {
    let key: CoreKey
    let isDown: Bool
}

private final class KeyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var transitions: [KeyTransition] = []

    func append(_ event: CoreKeyEvent) {
        lock.lock()
        transitions.append(KeyTransition(key: event.key, isDown: event.isDown))
        lock.unlock()
    }

    func snapshot() -> [KeyTransition] {
        lock.lock()
        defer { lock.unlock() }
        return transitions
    }
}
