import AppKit
import VideoPipeline
import XCTest

@testable import RustDeskNative

final class ViewerHUDTests: XCTestCase {
    @MainActor private func makeViewer(defaults: UserDefaults) -> (ViewerChromeView, NSWindow) {
        let video = ViewerMetalView(frame: .zero)
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test")
        let chrome = ViewerChromeView(
            videoView: video, metrics: metrics, showsAcceptanceControls: false,
            showsFileTransferControls: false, showsDisplayControls: false, showsAudioStatus: false,
            defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        return (chrome, window)
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "farpane-hud-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(true, forKey: "viewer.session-hud-visible.v1")
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor func testMetricRefreshFitsHUDAndPreservesItsDraggedPosition() async throws {
        _ = NSApplication.shared
        let defaults = try makeDefaults()
        let (chrome, window) = makeViewer(defaults: defaults)
        defer { window.contentView = nil }
        let panel = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ViewerHUDPanel }.first)
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test")
        chrome.updateHUD(metrics.hudSnapshot())
        chrome.layoutSubtreeIfNeeded()
        panel.onDrag?(NSPoint(x: 16, y: 16))
        panel.onDragEnded?()
        let originalOrigin = panel.frame.origin
        let originalSize = panel.frame.size
        metrics.recordCoreMetrics(remoteFPS: 30, networkDelayMS: 9_000, targetBitrate: 2_000_000)
        chrome.updateHUD(metrics.hudSnapshot())
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.origin, originalOrigin)
        XCTAssertGreaterThan(panel.frame.height, 80)
        XCTAssertGreaterThanOrEqual(panel.frame.width, originalSize.width)
        let label = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(panel.bounds.contains(label.frame))
        XCTAssertTrue(label.stringValue.contains("接收"))
        window.setContentSize(NSSize(width: 720, height: 480))
        chrome.layoutSubtreeIfNeeded()
        XCTAssertTrue(chrome.safeAreaRect.contains(panel.frame))
    }

    @MainActor func testHUDOwnsLabelHitTestingAndHiddenHUDLetsVideoReceiveInput() async throws {
        _ = NSApplication.shared
        let (chrome, window) = makeViewer(defaults: try makeDefaults())
        defer { window.contentView = nil }
        let panel = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ViewerHUDPanel }.first)
        let point = chrome.convert(NSPoint(x: panel.bounds.midX, y: panel.bounds.midY), from: panel)
        XCTAssertTrue(chrome.hitTest(point) === panel)
        panel.isHidden = true
        XCTAssertTrue(chrome.hitTest(point) === chrome.videoView)
    }

    @MainActor func testHUDStaysVisibleAfterResizeAndRestoresPositionInNextSession() async throws {
        _ = NSApplication.shared
        let defaults = try makeDefaults()
        let (chrome, window) = makeViewer(defaults: defaults)
        defer { window.contentView = nil }
        let panel = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ViewerHUDPanel }.first)
        panel.onDrag?(NSPoint(x: 10_000, y: -10_000))
        panel.onDragEnded?()
        XCTAssertEqual(
            defaults.array(forKey: "viewer.session-hud-position.v1") as? [Double], [1, 0])
        window.setContentSize(NSSize(width: 720, height: 480))
        chrome.layoutSubtreeIfNeeded()
        let available = chrome.safeAreaRect.insetBy(dx: 16, dy: 16)
        XCTAssertEqual(panel.frame.maxX, available.maxX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, available.minY, accuracy: 1)
        XCTAssertTrue(available.contains(panel.frame))
        let (nextChrome, nextWindow) = makeViewer(defaults: defaults)
        defer { nextWindow.contentView = nil }
        let nextPanel = try XCTUnwrap(
            nextChrome.subviews.compactMap { $0 as? ViewerHUDPanel }.first)
        let nextAvailable = nextChrome.safeAreaRect.insetBy(dx: 16, dy: 16)
        XCTAssertEqual(nextPanel.frame.maxX, nextAvailable.maxX, accuracy: 1)
        XCTAssertEqual(nextPanel.frame.minY, nextAvailable.minY, accuracy: 1)
    }

    @MainActor func testInvalidSavedPositionFallsBackAndAcceptanceDragDoesNotChangePreferences()
        async throws
    {
        _ = NSApplication.shared
        let defaults = try makeDefaults()
        defaults.set([Double.infinity, -1], forKey: "viewer.session-hud-position.v1")
        let (chrome, window) = makeViewer(defaults: defaults)
        defer { window.contentView = nil }
        let panel = try XCTUnwrap(chrome.subviews.compactMap { $0 as? ViewerHUDPanel }.first)
        XCTAssertEqual(panel.frame.midX, chrome.bounds.midX, accuracy: 1)
        XCTAssertTrue(chrome.safeAreaRect.contains(panel.frame))
        let acceptance = ViewerChromeView(
            videoView: ViewerMetalView(frame: .zero),
            metrics: PipelineMetrics(
                inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test"),
            showsAcceptanceControls: true, showsFileTransferControls: false,
            showsDisplayControls: false, showsAudioStatus: false, defaults: defaults)
        window.contentView = acceptance
        acceptance.layoutSubtreeIfNeeded()
        let acceptancePanel = try XCTUnwrap(
            acceptance.subviews.compactMap { $0 as? ViewerHUDPanel }.first)
        acceptancePanel.onDrag?(NSPoint(x: 16, y: 16))
        acceptancePanel.onDragEnded?()
        XCTAssertEqual(
            defaults.array(forKey: "viewer.session-hud-position.v1") as? [Double],
            [Double.infinity, -1])
    }

    @MainActor func testDraggingHUDMovesItWithoutResizingVideoOrSendingRemoteInput() async throws {
        _ = NSApplication.shared
        let video = ViewerMetalView(frame: .zero)
        var remoteInputCount = 0
        video.sendPointer = { _ in
            remoteInputCount += 1
            return 0
        }
        let metrics = PipelineMetrics(
            inputWidth: 0, inputHeight: 0, inputFPS: 30, selectedGPU: "test")
        let chrome = ViewerChromeView(
            videoView: video, metrics: metrics, showsAcceptanceControls: true,
            showsFileTransferControls: false, showsDisplayControls: false, showsAudioStatus: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = chrome
        chrome.layoutSubtreeIfNeeded()
        let panel = try XCTUnwrap(
            chrome.subviews.compactMap { $0 as? NSVisualEffectView }.first {
                $0.subviews.contains { ($0 as? NSTextField)?.stringValue == "正在等待视频…" }
            })
        let originalOrigin = panel.frame.origin
        let videoFrame = video.frame
        let location = panel.convert(NSPoint(x: 20, y: 20), to: nil)
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: 1))
        let drag = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: NSPoint(x: location.x + 100, y: location.y - 100), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2,
                clickCount: 1, pressure: 1))
        panel.mouseDown(with: down)
        panel.mouseDragged(with: drag)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.origin.x, originalOrigin.x + 100, accuracy: 1)
        XCTAssertEqual(panel.frame.origin.y, originalOrigin.y - 100, accuracy: 1)
        XCTAssertEqual(video.frame, videoFrame)
        XCTAssertEqual(remoteInputCount, 0)
    }
}
