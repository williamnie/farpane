import CoreBridge
import XCTest

final class HostApplicationLifecyclePolicyTests: XCTestCase {
    func testLastWindowCloseKeepsActiveHostAlive() {
        XCTAssertFalse(
            HostApplicationLifecyclePolicy.shouldTerminateAfterLastWindowClosed(
                hostRuntimeActive: true
            )
        )
    }

    func testLastWindowCloseStillTerminatesOrdinaryAppSession() {
        XCTAssertTrue(
            HostApplicationLifecyclePolicy.shouldTerminateAfterLastWindowClosed(
                hostRuntimeActive: false
            )
        )
    }
}
