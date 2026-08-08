import CoreBridge
import Foundation
import XCTest

final class HostAgentSnapshotPollingGateTests: XCTestCase {
    func testStartAndTickAreSingleOwnerAndNonReentrant() {
        let gate = HostAgentSnapshotPollingGate()

        XCTAssertTrue(gate.start())
        XCTAssertFalse(gate.start())
        XCTAssertTrue(gate.beginTick())
        XCTAssertFalse(gate.beginTick())
        gate.endTick()
        XCTAssertTrue(gate.beginTick())
        gate.endTick()
    }

    func testCancelBeforeStartPreventsStartAndTicks() {
        let gate = HostAgentSnapshotPollingGate()

        gate.cancelAndWait()
        XCTAssertFalse(gate.start())
        XCTAssertFalse(gate.beginTick())
        gate.cancelAndWait()
    }

    func testCancelWaitsForInFlightTickAndRejectsNewTicks() {
        let gate = HostAgentSnapshotPollingGate()
        XCTAssertTrue(gate.start())
        XCTAssertTrue(gate.beginTick())
        let cancelReturned = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            gate.cancelAndWait()
            cancelReturned.signal()
        }
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertFalse(gate.beginTick())
        gate.endTick()
        XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(gate.beginTick())
        gate.cancelAndWait()
    }
}
