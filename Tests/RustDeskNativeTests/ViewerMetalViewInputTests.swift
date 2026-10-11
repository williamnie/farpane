import AppKit
import CoreBridge
import XCTest

@testable import RustDeskNative

final class ViewerMetalViewInputTests: XCTestCase {
    @MainActor private func makeViewer() -> (ViewerMetalView, NSWindow) {
        _ = NSApplication.shared
        let view = ViewerMetalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.updateRemoteSize(width: 100, height: 100)
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return (view, window)
    }

    @MainActor private func mouseEvent(
        _ type: NSEvent.EventType, at point: NSPoint, view: ViewerMetalView,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: modifiers,
                timestamp: 0, windowNumber: view.window!.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: 1))
    }

    @MainActor func testClickWithoutPriorMotionPositionsRemotePointerBeforeButton() async throws {
        let (view, window) = makeViewer()
        defer { window.contentView = nil }
        var events: [CorePointerEvent] = []
        view.sendPointer = {
            events.append($0)
            return 0
        }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 75, y: 25), view: view))

        XCTAssertEqual(events.map(\.kind), [.move, .down])
        XCTAssertTrue(events.allSatisfy { $0.x == 75 && $0.y == 25 })
        XCTAssertEqual(events.first?.buttons, [])
        XCTAssertEqual(events.last?.buttons, .left)
    }

    @MainActor func testReleasePositionsPointerAtDragEndpointWithButtonStillHeld() async throws {
        let (view, window) = makeViewer()
        defer { window.contentView = nil }
        var events: [CorePointerEvent] = []
        view.sendPointer = {
            events.append($0)
            return 0
        }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 10), view: view))
        events.removeAll()
        view.mouseUp(
            with: try mouseEvent(
                .leftMouseUp, at: NSPoint(x: 90, y: 80), view: view, modifiers: .shift))

        XCTAssertEqual(events.map(\.kind), [.move, .up])
        XCTAssertTrue(events.allSatisfy { $0.x == 90 && $0.y == 80 })
        XCTAssertTrue(events.allSatisfy { $0.buttons == .left && $0.modifiers == .shift })
    }

    @MainActor func testButtonSupersedesOlderCoalescedPosition() async throws {
        let (view, window) = makeViewer()
        defer { window.contentView = nil }
        var events: [CorePointerEvent] = []
        view.sendPointer = {
            events.append($0)
            return 0
        }
        view.mouseMoved(with: try mouseEvent(.mouseMoved, at: NSPoint(x: 10, y: 10), view: view))
        view.rightMouseDown(
            with: try mouseEvent(.rightMouseDown, at: NSPoint(x: 70, y: 60), view: view))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(events.map(\.kind), [.move, .down])
        XCTAssertTrue(events.allSatisfy { $0.x == 70 && $0.y == 60 })
        XCTAssertEqual(events.last?.buttons, .right)
    }

    @MainActor func testQuiescedDisplayDoesNotSendButtonOrPosition() async throws {
        let (view, window) = makeViewer()
        defer { window.contentView = nil }
        var events: [CorePointerEvent] = []
        view.sendPointer = {
            events.append($0)
            return 0
        }
        view.releaseAllInputForDisplaySelection()
        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 75, y: 25), view: view))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 75, y: 25), view: view))
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor func testIMEOnlySendsCommittedUnicodeTextOnce() async {
        let (view, window) = makeViewer()
        defer { window.contentView = nil }
        var texts: [String] = []
        view.sendText = {
            texts.append($0)
            return 0
        }
        let replacement = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText(
            "zhongwen", selectedRange: NSRange(location: 8, length: 0),
            replacementRange: replacement)
        XCTAssertTrue(texts.isEmpty)
        view.insertText(NSAttributedString(string: "中文A🙂"), replacementRange: replacement)
        XCTAssertEqual(texts, ["中文A🙂"])
        XCTAssertFalse(view.hasMarkedText())
    }

    @MainActor func testCompatibilityPastesOnlyAfterIMECommitAndHonorsInputGates() async {
        let (view, window) = makeViewer()
        defer { window.contentView = nil }
        view.ubuntuPasteCompatibilityEnabled = true
        var calls: [String] = []
        view.sendText = { _ in
            calls.append("text")
            return 0
        }
        view.sendKey = {
            calls.append($0.isDown ? "down" : "up")
            return 0
        }
        let replacement = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText(
            "zhongwen", selectedRange: NSRange(location: 8, length: 0),
            replacementRange: replacement)
        XCTAssertTrue(calls.isEmpty)
        view.unmarkText()
        XCTAssertTrue(calls.isEmpty)
        view.insertText("中文", replacementRange: replacement)
        XCTAssertEqual(calls, ["text", "down", "up"])
        calls.removeAll()
        view.setKeyboardInputEnabled(false)
        view.insertText("中文", replacementRange: replacement)
        XCTAssertTrue(calls.isEmpty)
        view.setKeyboardInputEnabled(true)
        view.releaseAllInputForDisplaySelection()
        view.insertText("中文", replacementRange: replacement)
        XCTAssertTrue(calls.isEmpty)
    }
}
