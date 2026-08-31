import CoreBridge
import Foundation
import XCTest

final class HostAgentTerminationRequestLatchTests: XCTestCase {
    func testPreBindRequestIsDeliveredExactlyOnceWhenHandlerBinds() {
        let latch = HostAgentTerminationRequestLatch()
        var deliveries = 0

        XCTAssertTrue(latch.requestTermination())
        XCTAssertFalse(latch.requestTermination())
        XCTAssertTrue(latch.bind {
            deliveries += 1
        })
        XCTAssertEqual(deliveries, 1)
        XCTAssertFalse(latch.bind {
            deliveries += 1
        })
        XCTAssertFalse(latch.requestTermination())
        XCTAssertEqual(deliveries, 1)
    }

    func testPostBindRequestDeliversExactlyOnce() {
        let latch = HostAgentTerminationRequestLatch()
        var deliveries = 0

        XCTAssertTrue(latch.bind {
            deliveries += 1
        })
        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(latch.requestTermination())
        XCTAssertFalse(latch.requestTermination())
        XCTAssertEqual(deliveries, 1)
    }

    func testDeliveryRunsOutsideLockAndMayReenterWithoutDeadlock() {
        let latch = HostAgentTerminationRequestLatch()
        var reentrantRequest: Bool?

        XCTAssertTrue(latch.bind {
            reentrantRequest = latch.requestTermination()
        })
        XCTAssertTrue(latch.requestTermination())
        XCTAssertEqual(reentrantRequest, false)
    }

    func testDeliveredHandlerCaptureIsReleased() {
        let latch = HostAgentTerminationRequestLatch()
        var capture: LatchTestCapture? = LatchTestCapture()
        weak var weakCapture = capture
        var deliveries = 0

        XCTAssertTrue(latch.bind { [capture] in
            capture?.deliveryCount += 1
            deliveries += 1
        })
        capture = nil
        XCTAssertNotNil(weakCapture)
        XCTAssertTrue(latch.requestTermination())
        XCTAssertEqual(deliveries, 1)
        XCTAssertNil(weakCapture)
    }
}

private final class LatchTestCapture {
    var deliveryCount = 0
}
