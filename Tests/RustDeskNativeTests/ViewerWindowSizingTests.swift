import AppKit
import VideoPipeline
import XCTest

@testable import RustDeskNative

final class ViewerWindowSizingTests: XCTestCase {
    private let titlebarHeight: CGFloat = 28
    private let screen = NSRect(x: -1_920, y: 40, width: 1_920, height: 1_020)

    private func frame(_ remoteSize: NSSize, backingScale: CGFloat = 1) throws -> NSRect {
        try XCTUnwrap(
            ViewerWindowSizing.frame(
                remoteSize: remoteSize,
                currentFrame: NSRect(x: -1_500, y: 200, width: 1_000, height: 700),
                visibleFrame: screen, decorationSize: NSSize(width: 0, height: titlebarHeight),
                backingScale: backingScale))
    }

    func testRetinaUsesPhysicalPixelsAndAddsTitlebarOutsideVideo() throws {
        let result = try frame(NSSize(width: 2_560, height: 1_440), backingScale: 2)
        XCTAssertEqual(result.width, 1_280)
        XCTAssertEqual(result.height, 720 + titlebarHeight)
        XCTAssertEqual(result.midX, -1_000)
        XCTAssertEqual(result.midY, 550)
    }

    func testLargeRemoteFitsUsableScreenIncludingTitlebarWithoutLetterboxing() throws {
        let result = try frame(NSSize(width: 3_840, height: 2_160))
        XCTAssertEqual(result.height, screen.height)
        XCTAssertEqual(result.width / (result.height - titlebarHeight), 16.0 / 9, accuracy: 0.0001)
        XCTAssertTrue(screen.contains(result))
    }

    func testPortraitUltrawideAndSmallFramesKeepAspectRatioWithinScreen() throws {
        for remote in [
            NSSize(width: 1_080, height: 1_920), NSSize(width: 5_120, height: 1_440),
            NSSize(width: 640, height: 480), NSSize(width: 1_920, height: 1_200),
        ] {
            let result = try frame(remote, backingScale: 2)
            XCTAssertEqual(
                result.width / (result.height - titlebarHeight), remote.width / remote.height,
                accuracy: 0.0001)
            XCTAssertGreaterThan(result.width, 0)
            XCTAssertTrue(screen.contains(result))
        }
    }

    func testScreenLimitTakesPrecedenceOverMinimumWindowSize() throws {
        let available = NSRect(x: 300, y: -800, width: 600, height: 400)
        let result = try XCTUnwrap(
            ViewerWindowSizing.frame(
                remoteSize: NSSize(width: 2_560, height: 1_440), currentFrame: .zero,
                visibleFrame: available, decorationSize: NSSize(width: 0, height: titlebarHeight),
                backingScale: 2))
        XCTAssertEqual(result.width, 600)
        XCTAssertEqual(result.height, 337.5 + titlebarHeight)
        XCTAssertTrue(available.contains(result))
    }

    func testInvalidDimensionsDoNotProduceWindowFrame() {
        for size in [
            NSSize.zero, NSSize(width: -1, height: 1), NSSize(width: CGFloat.infinity, height: 1),
        ] {
            XCTAssertNil(
                ViewerWindowSizing.frame(
                    remoteSize: size, currentFrame: .zero, visibleFrame: screen,
                    decorationSize: .zero, backingScale: 2))
        }
    }

    @MainActor private func makeViewer(automaticallySizesWindow: Bool = true) -> (
        ViewerChromeView, NSWindow
    ) {
        _ = NSApplication.shared
        let chrome = ViewerChromeView(
            videoView: ViewerMetalView(frame: .zero),
            metrics: PipelineMetrics(
                inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test"),
            showsAcceptanceControls: false, showsFileTransferControls: false,
            showsDisplayControls: false, showsAudioStatus: false,
            automaticallySizesWindow: automaticallySizesWindow)
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.contentView = chrome
        return (chrome, window)
    }

    @MainActor private func assertVideoFits(
        _ chrome: ViewerChromeView, window: NSWindow, aspect: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(chrome.videoView.frame, chrome.bounds, file: file, line: line)
        XCTAssertEqual(
            chrome.bounds.width, chrome.bounds.height * aspect, accuracy: 1, file: file, line: line)
        let visibleFrame = try XCTUnwrap(window.screen ?? NSScreen.main).visibleFrame
        XCTAssertTrue(
            visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame), file: file, line: line)
    }

    @MainActor func testFirstResolutionFitsVideoAndRepeatedFramesPreserveManualSize() async throws {
        let (chrome, window) = makeViewer()
        defer { window.contentView = nil }
        chrome.updateRemoteSize(width: 2_560, height: 1_440)
        try assertVideoFits(chrome, window: window, aspect: 16.0 / 9)

        window.setContentSize(NSSize(width: 900, height: 600))
        let manualFrame = window.frame
        chrome.updateRemoteSize(width: 2_560, height: 1_440)
        XCTAssertEqual(window.frame, manualFrame)
        chrome.updateRemoteSize(width: 0, height: 0)
        XCTAssertEqual(window.frame, manualFrame)

        chrome.updateRemoteSize(width: 1_920, height: 1_200)
        try assertVideoFits(chrome, window: window, aspect: 16.0 / 10)
    }

    @MainActor func testPortraitAndUltrawideOverrideOldMinimumWithoutBlackBars() async throws {
        let (chrome, window) = makeViewer()
        defer { window.contentView = nil }
        chrome.updateRemoteSize(width: 1_080, height: 1_920)
        try assertVideoFits(chrome, window: window, aspect: 9.0 / 16)
        chrome.updateRemoteSize(width: 5_120, height: 1_440)
        try assertVideoFits(chrome, window: window, aspect: 32.0 / 9)
    }

    @MainActor func testFullscreenTransitionDefersAndCoalescesResolutionChanges() async throws {
        let (chrome, window) = makeViewer()
        defer { window.contentView = nil }
        let center = NotificationCenter.default
        let original = window.frame
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        chrome.updateRemoteSize(width: 2_560, height: 1_440)
        chrome.updateRemoteSize(width: 1_600, height: 1_200)
        XCTAssertEqual(window.frame, original)
        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        XCTAssertEqual(window.frame, original)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        try assertVideoFits(chrome, window: window, aspect: 4.0 / 3)
    }

    @MainActor func testDetachedViewerCannotResizeHomeWindow() async {
        let (chrome, window) = makeViewer()
        window.contentView = NSView()
        let original = window.frame
        chrome.updateRemoteSize(width: 1_080, height: 1_920)
        NotificationCenter.default.post(
            name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(window.frame, original)
        window.contentView = nil
    }

    @MainActor func testDisabledAutomaticSizingPreservesAcceptanceWindow() async {
        let (chrome, window) = makeViewer(automaticallySizesWindow: false)
        defer { window.contentView = nil }
        let original = window.frame
        chrome.updateRemoteSize(width: 1_080, height: 1_920)
        XCTAssertEqual(window.frame, original)
    }
}
