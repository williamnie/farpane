import CoreBridge
import XCTest

final class HostApplicationLifecyclePolicyTests: XCTestCase {
    func testProductProcessModeRecognizesOnlyExactHostAgentFlag() {
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: ["FarPane"]),
            .application
        )
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: [
                "FarPane", "--fixture", "sample.h265", "--host-agent",
            ]),
            .hostAgent
        )
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: [
                "FarPane", "--host-agent=false",
            ]),
            .application
        )
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: [
                "FarPaneHostAgent", "--cm",
            ]),
            .unsupportedConnectionManager
        )
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: [
                "FarPaneHostAgent", "--cm-no-ui",
            ]),
            .unsupportedConnectionManager
        )
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: [
                "FarPaneHostAgent", "--host-agent", "--cm",
            ]),
            .unsupportedConnectionManager
        )
        XCTAssertEqual(
            RustDeskNativeProcessModePolicy.resolve(arguments: [
                "FarPane", "--cm=false",
            ]),
            .application
        )
        XCTAssertEqual(
            RustDeskNativeConnectionManagerRejectionPolicy.exitCode,
            64
        )
        XCTAssertEqual(
            RustDeskNativeConnectionManagerRejectionPolicy.diagnostic,
            "FarPane connection-manager mode is unsupported.\n"
        )
    }

    func testLastWindowCloseKeepsActiveHostAlive() {
        XCTAssertFalse(
            HostApplicationLifecyclePolicy.shouldTerminateAfterLastWindowClosed(
                hostRuntimeActive: true
            )
        )
    }

    func testLastWindowCloseKeepsOrdinaryAppSessionAlive() {
        XCTAssertFalse(
            HostApplicationLifecyclePolicy.shouldTerminateAfterLastWindowClosed(
                hostRuntimeActive: false
            )
        )
    }

    func testViewerContentSizeResetOnlyAppliesToWindowedMode() {
        XCTAssertTrue(
            ProductWindowTransitionPolicy.shouldResetWindowedContentSize(
                isFullScreen: false
            )
        )
        XCTAssertFalse(
            ProductWindowTransitionPolicy.shouldResetWindowedContentSize(
                isFullScreen: true
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

        let lockedViewOnly = HostSessionIndicatorPolicy.presentation(
            connectionID: "host:session-1",
            remoteID: "peer-1",
            remoteName: "MacBook Pro",
            activeAquaSessionAvailable: false,
            inputAvailability: .disabled,
            inputUnavailableReason: .localPolicyDisabled,
            disconnectInFlight: false
        )
        XCTAssertEqual(lockedViewOnly?.title, "FarPane 远程会话受限")
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

    func testActiveAquaSessionAllowsCaptureOnlyForUnlockedLoggedInConsoleUser() {
        XCTAssertTrue(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: true,
            loginDone: true,
            screenLocked: false
        ))
        XCTAssertTrue(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: true,
            loginDone: true,
            screenLocked: nil
        ))
        XCTAssertTrue(HostActiveAquaSessionPolicy.isAvailable(sessionDictionary: [
            "kCGSSessionOnConsoleKey": true,
            "kCGSessionLoginDoneKey": true,
        ]))

        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: false,
            loginDone: true,
            screenLocked: false
        ))
        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: true,
            loginDone: false,
            screenLocked: false
        ))
        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: true,
            loginDone: true,
            screenLocked: true
        ))
    }

    func testActiveAquaSessionPolicyFailsClosedWhenRequiredFlagsAreMissing() {
        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: nil,
            loginDone: true,
            screenLocked: false
        ))
        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(
            onConsole: true,
            loginDone: nil,
            screenLocked: false
        ))

        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(sessionDictionary: [
            "kCGSSessionOnConsoleKey": 1,
            "kCGSessionLoginDoneKey": true,
        ]))
        XCTAssertFalse(HostActiveAquaSessionPolicy.isAvailable(sessionDictionary: [
            "kCGSSessionOnConsoleKey": true,
            "kCGSessionLoginDoneKey": true,
            "CGSSessionScreenIsLocked": "false",
        ]))
    }

    func testSessionPresentationMakesAquaAvailabilityOverrideInputStatus() {
        let lockedViewOnly = HostSessionPresentationPolicy.presentation(
            activeAquaSessionAvailable: false,
            inputAvailability: .disabled,
            inputUnavailableReason: .localPolicyDisabled
        )
        XCTAssertEqual(
            lockedViewOnly?.overallStatusText,
            "远程会话受限：当前 Mac 会话不可用"
        )
        XCTAssertEqual(
            lockedViewOnly?.detailText,
            "当前版本不支持在锁屏、登录窗口或其他用户会话中远程操作；画面采集已暂停，远程键盘与鼠标不可用"
        )
        XCTAssertEqual(lockedViewOnly?.statusItemTitle, "FarPane 远程会话受限")

        let lockedAccessibilityDenied = HostSessionPresentationPolicy.presentation(
            activeAquaSessionAvailable: false,
            inputAvailability: .limited,
            inputUnavailableReason: .accessibilityDenied
        )
        XCTAssertEqual(lockedAccessibilityDenied, lockedViewOnly)

        let activeAccessibilityDenied = HostSessionPresentationPolicy.presentation(
            activeAquaSessionAvailable: true,
            inputAvailability: .limited,
            inputUnavailableReason: .accessibilityDenied
        )
        XCTAssertEqual(
            activeAccessibilityDenied,
            HostSessionInputPresentationPolicy.presentation(
                availability: .limited,
                unavailableReason: .accessibilityDenied
            )
        )

        XCTAssertNil(HostSessionPresentationPolicy.presentation(
            activeAquaSessionAvailable: false,
            inputAvailability: .available,
            inputUnavailableReason: .sessionUnavailable
        ))
    }

    func testBackgroundPresentationConsumesStrictTopLevelSessionTuple() {
        let available = HostSessionPresentationPolicy.presentation(
            sessionAvailability: .available,
            sessionUnavailableReason: nil,
            inputAvailability: .available,
            inputUnavailableReason: nil
        )
        XCTAssertEqual(available?.overallStatusText, "远程会话进行中")

        let limited = HostSessionPresentationPolicy.presentation(
            sessionAvailability: .limited,
            sessionUnavailableReason: .sessionUnavailable,
            inputAvailability: .limited,
            inputUnavailableReason: .sessionUnavailable
        )
        XCTAssertEqual(
            limited?.overallStatusText,
            "远程会话受限：当前 Mac 会话不可用"
        )
        XCTAssertEqual(
            limited?.detailText,
            "当前版本不支持在锁屏、登录窗口或其他用户会话中远程操作；画面采集已暂停，远程键盘与鼠标不可用"
        )

        XCTAssertNil(HostSessionPresentationPolicy.presentation(
            sessionAvailability: .available,
            sessionUnavailableReason: .sessionUnavailable,
            inputAvailability: .available,
            inputUnavailableReason: nil
        ))
        XCTAssertNil(HostSessionPresentationPolicy.presentation(
            sessionAvailability: .limited,
            sessionUnavailableReason: nil,
            inputAvailability: .limited,
            inputUnavailableReason: .sessionUnavailable
        ))
        XCTAssertNil(HostSessionPresentationPolicy.presentation(
            sessionAvailability: .available,
            sessionUnavailableReason: nil,
            inputAvailability: .limited,
            inputUnavailableReason: .sessionUnavailable
        ))
        XCTAssertNil(HostSessionPresentationPolicy.presentation(
            sessionAvailability: .limited,
            sessionUnavailableReason: .sessionUnavailable,
            inputAvailability: .limited,
            inputUnavailableReason: .accessibilityDenied
        ))
    }
}
