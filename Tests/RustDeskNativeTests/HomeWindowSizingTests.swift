import AppKit
import VideoPipeline
import XCTest

@testable import RustDeskNative

final class HomeWindowSizingTests: XCTestCase {
    private final class TestWindow: NSWindow {
        var simulatesFullscreen = false

        override var styleMask: NSWindow.StyleMask {
            get { simulatesFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
            set { super.styleMask = newValue }
        }
    }

    @MainActor private func makeWindow() -> TestWindow {
        _ = NSApplication.shared
        let window = TestWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1060, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = HomeView()
        return window
    }

    @MainActor private func contentSize(_ window: NSWindow) -> NSSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    @MainActor private func showViewer(in window: NSWindow, sizer: HomeWindowSizer)
        -> ViewerChromeView
    {
        sizer.leaveHome()
        let chrome = ViewerChromeView(
            videoView: ViewerMetalView(frame: .zero),
            metrics: PipelineMetrics(
                inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test"),
            showsAcceptanceControls: false, showsFileTransferControls: false,
            showsDisplayControls: false, showsAudioStatus: false, automaticallySizesWindow: true)
        window.contentView = chrome
        chrome.updateRemoteSize(width: 2_560, height: 1_440)
        return chrome
    }

    @MainActor func testRemoteResolutionDoesNotBecomeHomeSizeAndLateFramesCannotResizeHome() async {
        let window = makeWindow()
        defer { window.contentView = nil }
        let sizer = HomeWindowSizer()
        sizer.showHome(in: window)
        let original = contentSize(window)
        let chrome = showViewer(in: window, sizer: sizer)
        XCTAssertNotEqual(contentSize(window), original)

        window.contentView = HomeView()
        sizer.showHome(in: window)
        XCTAssertEqual(contentSize(window), NSSize(width: 1060, height: 720))
        chrome.updateRemoteSize(width: 1_080, height: 1_920)
        XCTAssertEqual(contentSize(window), original)
    }

    @MainActor func testManualHomeSizeSurvivesRepeatedSessionsAndViewerResizing() async {
        let window = makeWindow()
        defer { window.contentView = nil }
        let sizer = HomeWindowSizer()
        sizer.showHome(in: window)
        for manualSize in [NSSize(width: 1200, height: 800), NSSize(width: 950, height: 650)] {
            window.setContentSize(manualSize)
            for _ in 0..<2 {
                _ = showViewer(in: window, sizer: sizer)
                window.setContentSize(NSSize(width: 900, height: 600))
                sizer.leaveHome()
                window.contentView = HomeView()
                sizer.showHome(in: window)
                XCTAssertEqual(contentSize(window), manualSize)
            }
        }
    }

    @MainActor func testShowingHomeAgainWithoutLaunchingViewerPreservesManualSize() async {
        let window = makeWindow()
        defer { window.contentView = nil }
        let sizer = HomeWindowSizer()
        sizer.showHome(in: window)
        let manualSize = NSSize(width: 1200, height: 800)
        window.setContentSize(manualSize)
        window.contentView = HomeView()
        sizer.showHome(in: window)
        XCTAssertEqual(contentSize(window), manualSize)
    }

    @MainActor func testFullscreenHomeDoesNotOverwriteWindowedSizeAndRestoresAfterExit() async {
        let window = makeWindow()
        defer { window.contentView = nil }
        let sizer = HomeWindowSizer()
        sizer.showHome(in: window)
        let manualSize = NSSize(width: 1200, height: 800)
        window.setContentSize(manualSize)
        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setContentSize(NSSize(width: 1600, height: 900))
        _ = showViewer(in: window, sizer: sizer)
        let fullscreenFrame = window.frame
        window.contentView = HomeView()
        sizer.showHome(in: window)
        sizer.showHome(in: window)
        XCTAssertEqual(window.frame, fullscreenFrame)

        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        XCTAssertEqual(window.frame, fullscreenFrame)
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(contentSize(window), manualSize)
    }

    @MainActor func testNewViewerCancelsPendingHomeRestorationDuringFullscreenExit() async {
        let window = makeWindow()
        defer { window.contentView = nil }
        let sizer = HomeWindowSizer()
        sizer.showHome(in: window)
        sizer.leaveHome()
        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.simulatesFullscreen = true
        window.setContentSize(NSSize(width: 1600, height: 900))
        center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        center.post(name: NSWindow.willExitFullScreenNotification, object: window)
        sizer.showHome(in: window)
        sizer.leaveHome()
        let viewerFrame = window.frame
        window.simulatesFullscreen = false
        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(window.frame, viewerFrame)

        sizer.showHome(in: window)
        XCTAssertEqual(contentSize(window), NSSize(width: 1060, height: 720))
    }

    @MainActor func testReturningFromSettledFullscreenRestoresOnlyAfterExiting() async {
        for entersFromHome in [true, false] {
            let window = makeWindow()
            defer { window.contentView = nil }
            let sizer = HomeWindowSizer()
            sizer.showHome(in: window)
            let manualSize = NSSize(width: 1200, height: 800)
            window.setContentSize(manualSize)
            if !entersFromHome { sizer.leaveHome() }
            let center = NotificationCenter.default
            center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            window.simulatesFullscreen = true
            window.setContentSize(NSSize(width: 1600, height: 900))
            center.post(name: NSWindow.didEnterFullScreenNotification, object: window)
            if entersFromHome { sizer.leaveHome() }
            let fullscreenFrame = window.frame
            sizer.showHome(in: window)
            XCTAssertEqual(window.frame, fullscreenFrame)

            center.post(name: NSWindow.willExitFullScreenNotification, object: window)
            window.simulatesFullscreen = false
            center.post(name: NSWindow.didExitFullScreenNotification, object: window)
            XCTAssertEqual(contentSize(window), manualSize)
        }
    }
}
