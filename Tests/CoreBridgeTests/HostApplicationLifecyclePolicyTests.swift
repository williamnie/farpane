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

    func testActiveSessionIndicatorRequiresExactValidatedSession() {
        XCTAssertNil(
            HostSessionIndicatorPolicy.presentation(
                connectionID: nil,
                remoteID: "peer-1",
                remoteName: "MacBook Pro",
                disconnectInFlight: false
            )
        )
        XCTAssertNil(
            HostSessionIndicatorPolicy.presentation(
                connectionID: "",
                remoteID: "peer-1",
                remoteName: "MacBook Pro",
                disconnectInFlight: false
            )
        )
        XCTAssertNil(
            HostSessionIndicatorPolicy.presentation(
                connectionID: "host:session\n2",
                remoteID: "peer-1",
                remoteName: "MacBook Pro",
                disconnectInFlight: false
            )
        )

        let presentation = HostSessionIndicatorPolicy.presentation(
            connectionID: "host:session-1",
            remoteID: "peer-1",
            remoteName: "MacBook Pro",
            disconnectInFlight: false
        )
        XCTAssertEqual(presentation?.connectionID, "host:session-1")
        XCTAssertEqual(presentation?.title, "FarPane 正在共享屏幕")
        XCTAssertEqual(
            presentation?.remoteIdentityText,
            "对方声明（未经验证）：MacBook Pro · ID peer-1"
        )
        XCTAssertEqual(presentation?.disconnectTitle, "断开连接")
        XCTAssertEqual(presentation?.disconnectEnabled, true)

        let fallback = HostSessionIndicatorPolicy.presentation(
            connectionID: "host:session-1",
            remoteID: "peer-1",
            remoteName: "",
            disconnectInFlight: true
        )
        XCTAssertEqual(
            fallback?.remoteIdentityText,
            "对方声明（未经验证）：peer-1"
        )
        XCTAssertEqual(fallback?.disconnectTitle, "正在断开…")
        XCTAssertEqual(fallback?.disconnectEnabled, false)
    }
}
