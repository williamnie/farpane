import AppKit
import ConnectionCatalog
import XCTest

@testable import RustDeskNative

final class HomeViewTests: XCTestCase {
    @MainActor func testAllPagesConstructAndNavigationSelectsTheActualContent() async throws {
        _ = NSApplication.shared
        let view = HomeView(frame: NSRect(x: 0, y: 0, width: 1060, height: 720))
        XCTAssertEqual(view.pageTabView.numberOfTabViewItems, 3)
        for page in HomePage.allCases {
            let button = try XCTUnwrap(view.sidebarButtons[page])
            button.performClick(nil)
            XCTAssertEqual(view.selectedPage, page)
            XCTAssertEqual(
                view.pageTabView.selectedTabViewItem?.identifier as? String, page.rawValue)
        }
    }

    @MainActor func testEachClipboardControlRoutesExactlyOneIndependentPreference() async throws {
        _ = NSApplication.shared
        let view = HomeView()
        var snapshot = view.snapshot
        snapshot.host.allowsClipboardPolicyChange = true
        view.apply(snapshot)
        var calls: [(HostClipboardPreference, Bool)] = []
        view.onHostClipboardToggle = { calls.append(($0, $1)) }
        XCTAssertEqual(view.clipboardControls.map(\.preference), HostClipboardPreference.allCases)
        for entry in view.clipboardControls {
            XCTAssertTrue(entry.control.isEnabled)
            XCTAssertEqual(entry.control.state, .off)
            entry.control.state = .on
            XCTAssertTrue(entry.control.sendAction(entry.control.action, to: entry.control.target))
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(calls.first?.0, entry.preference)
            XCTAssertEqual(calls.first?.1, true)
            calls.removeAll()
        }
        snapshot.host.allowsClipboardPolicyChange = false
        view.apply(snapshot)
        for entry in view.clipboardControls {
            XCTAssertFalse(entry.control.isEnabled)
            view.hostClipboardToggleChanged(entry.control)
        }
        XCTAssertTrue(calls.isEmpty)
        view.hostClipboardToggleChanged(NSSwitch())
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor func testBusyConnectionDisablesPolicyChangesAndAudioSelectionSurvivesRefresh() async
    {
        _ = NSApplication.shared
        let view = HomeView()
        var snapshot = view.snapshot
        snapshot.host.allowsClipboardPolicyChange = true
        snapshot.host.allowsAudioPolicyChange = true
        snapshot.host.audioInputDeviceNames = ["Virtual Input", "Microphone"]
        snapshot.host.audioInputDeviceName = "Virtual Input"
        view.apply(snapshot)
        XCTAssertEqual(
            view.hostAudioInputPopup.selectedItem?.representedObject as? String, "Virtual Input")
        snapshot.host.audioInputDeviceNames = ["Microphone"]
        snapshot.host.audioInputDeviceAvailable = false
        snapshot.connectingPeerID = "123456789"
        view.apply(snapshot)
        XCTAssertEqual(
            view.hostAudioInputPopup.selectedItem?.representedObject as? String, "Virtual Input")
        XCTAssertFalse(view.hostAudioInputPopup.isEnabled)
        XCTAssertTrue(view.clipboardControls.allSatisfy { !$0.control.isEnabled })
    }
}
