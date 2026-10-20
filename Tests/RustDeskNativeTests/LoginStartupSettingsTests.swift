import AppKit
import ServiceManagement
import XCTest

@testable import RustDeskNative

final class LoginStartupSettingsTests: XCTestCase {
    func testOptInPersistsAcrossOwnersAndExternalChangesAreObserved() {
        var systemStatus = SMAppService.Status.notRegistered
        var writes = 0
        let settings = LoginStartupSettings(
            status: { systemStatus },
            register: {
                writes += 1
                systemStatus = .enabled
            },
            unregister: {
                writes += 1
                systemStatus = .notRegistered
            })
        XCTAssertFalse(settings.presentation().isEnabled)
        XCTAssertEqual(writes, 0)
        settings.setEnabled(true)
        XCTAssertTrue(settings.presentation().isEnabled)
        settings.setEnabled(true)
        XCTAssertEqual(writes, 1)
        let reopened = LoginStartupSettings(status: { systemStatus })
        XCTAssertTrue(reopened.presentation().isEnabled)
        systemStatus = .notRegistered
        reopened.refresh()
        XCTAssertFalse(reopened.presentation().isEnabled)
    }

    func testApprovalIsPendingAndCanBeCancelled() {
        var systemStatus = SMAppService.Status.notRegistered
        let settings = LoginStartupSettings(
            status: { systemStatus }, register: { systemStatus = .requiresApproval },
            unregister: { systemStatus = .notRegistered })
        settings.setEnabled(true)
        XCTAssertTrue(settings.presentation().needsApproval)
        XCTAssertTrue(settings.presentation().isEnabled)
        settings.setEnabled(false)
        XCTAssertFalse(settings.presentation().needsApproval)
        XCTAssertFalse(settings.presentation().isEnabled)
    }

    func testFailureAndIneffectiveMutationNeverClaimSuccess() {
        struct Denied: Error {}
        let settings = LoginStartupSettings(
            status: { .notRegistered }, register: { throw Denied() }, unregister: {})
        settings.setEnabled(true)
        XCTAssertFalse(settings.presentation().isEnabled)
        XCTAssertTrue(settings.presentation().message.contains("失败"))
        let ineffective = LoginStartupSettings(status: { .enabled }, register: {}, unregister: {})
        ineffective.setEnabled(false)
        XCTAssertTrue(ineffective.presentation().isEnabled)
        XCTAssertTrue(ineffective.presentation().message.contains("尚未应用"))
    }

    func testMissingApplicationCannotRegister() {
        var writes = 0
        let settings = LoginStartupSettings(
            status: { .notFound }, register: { writes += 1 }, unregister: { writes += 1 })
        settings.setEnabled(true)
        XCTAssertFalse(settings.presentation().canChange)
        XCTAssertEqual(writes, 0)
    }

    @MainActor func testSwitchRoutesOnlyUserChangesAndShowsApprovalAction() async {
        _ = NSApplication.shared
        let view = HomeView()
        var changes: [Bool] = []
        view.onLoginStartupToggle = { changes.append($0) }
        view.applyLoginStartup(
            LoginStartupPresentation(
                isEnabled: true, canChange: true, needsApproval: true, message: "等待系统允许"))
        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(view.loginStartupSystemSettingsButton.isHidden)
        view.loginStartupSwitch.state = .off
        view.loginStartupChanged()
        XCTAssertEqual(changes, [false])
        view.applyLoginStartup(
            LoginStartupPresentation(
                isEnabled: false, canChange: false, needsApproval: false, message: "不可用"))
        view.loginStartupChanged()
        XCTAssertEqual(changes, [false])
    }

    @MainActor func testStartupSettingsRemainVisibleAtMinimumWindowSize() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = HomeView()
        window.contentView = view
        view.applyLoginStartup(
            LoginStartupPresentation(
                isEnabled: false, canChange: true, needsApproval: false,
                message: "未开启：重启并登录后需要手动打开 FarPane。"))
        view.sidebarButtons[.sharing]?.performClick(nil)
        view.layoutSubtreeIfNeeded()
        let toggle = view.loginStartupSwitch.convert(view.loginStartupSwitch.bounds, to: view)
        XCTAssertGreaterThan(toggle.width, 0)
        XCTAssertTrue(view.bounds.contains(toggle))
        XCTAssertGreaterThan(view.loginStartupStatusLabel.bounds.width, 200)
        if let destination = ProcessInfo.processInfo.environment["FARPANE_STARTUP_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: destination))
        }
        window.contentView = nil
    }
}
