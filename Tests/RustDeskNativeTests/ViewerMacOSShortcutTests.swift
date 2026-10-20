import AppKit
import CoreBridge
import VideoPipeline
import ViewerInput
import XCTest

@testable import RustDeskNative

final class ViewerMacOSShortcutTests: XCTestCase {
    func testEachShortcutSendsExactlyOnePhysicalKeyPairWithoutModifiers() {
        for (shortcut, code) in zip(ViewerMacOSShortcut.allCases, [131, 160, 103] as [UInt16]) {
            let finished = expectation(description: shortcut.title)
            let events = ShortcutEventRecorder()
            let dispatcher = ExclusiveKeyboardEventDispatcher(
                send: {
                    events.append($0)
                    return 0
                }, recordResult: { _, _ in })
            dispatcher.enqueueKeyPress(shortcut.key) {
                XCTAssertEqual($0, 0)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 1)
            let snapshot = events.snapshot()
            XCTAssertEqual(snapshot.map(\.key), [.physical(code), .physical(code)])
            XCTAssertEqual(snapshot.map(\.isDown), [true, false])
            XCTAssertTrue(snapshot.allSatisfy { $0.modifiers.isEmpty })
        }
    }

    func testFailedDownStillReleasesKeyAndReportsFirstFailure() {
        for downResult: Int32 in [-6, 0] {
            let finished = expectation(description: "按键释放")
            let events = ShortcutEventRecorder()
            let dispatcher = ExclusiveKeyboardEventDispatcher(
                send: {
                    events.append($0)
                    return $0.isDown ? downResult : -3
                }, recordResult: { _, _ in })
            dispatcher.enqueueKeyPress(ViewerMacOSShortcut.launchpad.key) {
                XCTAssertEqual($0, downResult == 0 ? -3 : downResult)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 1)
            XCTAssertEqual(events.snapshot().map(\.isDown), [true, false])
        }
    }

    @MainActor func testToolbarHidesUnknownPeerAndResetsAvailabilityBetweenConnections()
        async throws
    {
        _ = NSApplication.shared
        let chrome = makeChrome()
        let buttons = descendantButtons(chrome).filter { $0.toolTip?.hasPrefix("远端 Mac：") == true }
        XCTAssertEqual(buttons.count, 3)
        XCTAssertTrue(buttons.allSatisfy { $0.isHiddenOrHasHiddenAncestor && !$0.isEnabled })
        var actions: [ViewerMacOSShortcut] = []
        chrome.onMacOSShortcut = { actions.append($0) }
        chrome.setMacOSShortcutsAvailable(true)
        for button in buttons {
            XCTAssertTrue(button.isEnabled)
            XCTAssertNotNil(button.image)
            button.performClick(nil)
        }
        XCTAssertEqual(actions, ViewerMacOSShortcut.allCases)
        chrome.setMacOSShortcutsAvailable(false)
        for button in buttons { button.performClick(nil) }
        XCTAssertEqual(actions.count, 3)
        XCTAssertTrue(buttons.allSatisfy { !$0.isEnabled })
        chrome.resetMacOSShortcuts()
        XCTAssertTrue(buttons.allSatisfy { $0.isHiddenOrHasHiddenAncestor && !$0.isEnabled })
    }

    @MainActor func testShortcutRowFitsSmallWindowAndReturnsFocusToVideo() async throws {
        _ = NSApplication.shared
        let chrome = makeChrome(showsSessionControls: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        defer { window.contentView = nil }
        chrome.setMacOSShortcutsAvailable(true)
        try XCTUnwrap(descendantButtons(chrome).first { $0.toolTip == "打开会话控制" }).performClick(nil)
        chrome.layoutSubtreeIfNeeded()
        let buttons = descendantButtons(chrome).filter { $0.toolTip?.hasPrefix("远端 Mac：") == true }
        for button in buttons {
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor)
            let rect = chrome.convert(button.bounds, from: button)
            XCTAssertTrue(chrome.bounds.contains(rect), "\(rect)")
            XCTAssertGreaterThan(rect.width, 20)
            XCTAssertGreaterThan(rect.height, 16)
        }
        buttons[0].performClick(nil)
        XCTAssertTrue(window.firstResponder === chrome.videoView)
    }

    @MainActor private func makeChrome(showsSessionControls: Bool = false) -> ViewerChromeView {
        ViewerChromeView(
            videoView: ViewerMetalView(frame: .zero),
            metrics: PipelineMetrics(
                inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test"),
            showsAcceptanceControls: false, showsFileTransferControls: showsSessionControls,
            showsDisplayControls: showsSessionControls, showsAudioStatus: showsSessionControls)
    }

    @MainActor private func descendantButtons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { descendantButtons($0) }
    }
}

private final class ShortcutEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CoreKeyEvent] = []

    func append(_ event: CoreKeyEvent) { lock.withLock { events.append(event) } }
    func snapshot() -> [CoreKeyEvent] { lock.withLock { events } }
}
