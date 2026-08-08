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

        let limited = HostSessionIndicatorPolicy.presentation(
            connectionID: "host:session-1",
            remoteID: "peer-1",
            remoteName: "MacBook Pro",
            inputAvailability: .limited,
            inputUnavailableReason: .sessionUnavailable,
            disconnectInFlight: false
        )
        XCTAssertEqual(limited?.title, "FarPane 远程会话受限")
    }

    func testInputPresentationExplainsAuthoritativeLimitAndRejectsContradictions() {
        let sessionUnavailable = HostSessionInputPresentationPolicy.presentation(
            availability: .limited,
            unavailableReason: .sessionUnavailable
        )
        XCTAssertEqual(
            sessionUnavailable?.overallStatusText,
            "远程会话受限：当前 Mac 会话不可用"
        )
        XCTAssertEqual(
            sessionUnavailable?.detailText,
            "键盘与鼠标已暂停：当前 Mac 处于锁屏、登录窗口或其他用户会话"
        )
        XCTAssertEqual(sessionUnavailable?.statusItemTitle, "FarPane 远程会话受限")

        let locallyDisabled = HostSessionInputPresentationPolicy.presentation(
            availability: .disabled,
            unavailableReason: .localPolicyDisabled
        )
        XCTAssertEqual(locallyDisabled?.overallStatusText, "远程会话进行中")
        XCTAssertEqual(locallyDisabled?.detailText, "键盘与鼠标已由本机停用")

        let accessibilityDenied = HostSessionInputPresentationPolicy.presentation(
            availability: .limited,
            unavailableReason: .accessibilityDenied
        )
        XCTAssertEqual(
            accessibilityDenied?.detailText,
            "键盘与鼠标已暂停：重新授权后，请在本机重新启用键鼠控制"
        )

        XCTAssertNil(HostSessionInputPresentationPolicy.presentation(
            availability: .available,
            unavailableReason: .sessionUnavailable
        ))
        XCTAssertNil(HostSessionInputPresentationPolicy.presentation(
            availability: .disabled,
            unavailableReason: .accessibilityDenied
        ))
        XCTAssertNil(HostSessionInputPresentationPolicy.presentation(
            availability: .limited,
            unavailableReason: .remoteDisabled
        ))
    }
}
