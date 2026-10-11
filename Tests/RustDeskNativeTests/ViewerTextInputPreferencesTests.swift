import Foundation
import XCTest

@testable import RustDeskNative

final class ViewerTextInputPreferencesTests: XCTestCase {
    func testCompatibilityIsOptInAndRememberedOnlyForSelectedDevice() throws {
        let suite = "farpane-text-input-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ubuntu = UUID()
        let otherDevice = UUID()
        XCTAssertFalse(ViewerTextInputPreferences.isEnabled(deviceID: ubuntu, defaults: defaults))
        ViewerTextInputPreferences.setEnabled(true, deviceID: ubuntu, defaults: defaults)
        XCTAssertTrue(ViewerTextInputPreferences.isEnabled(deviceID: ubuntu, defaults: defaults))
        XCTAssertFalse(
            ViewerTextInputPreferences.isEnabled(deviceID: otherDevice, defaults: defaults))
        XCTAssertFalse(ViewerTextInputPreferences.isEnabled(deviceID: nil, defaults: defaults))
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(ViewerTextInputPreferences.isEnabled(deviceID: ubuntu, defaults: reloaded))
        ViewerTextInputPreferences.setEnabled(false, deviceID: ubuntu, defaults: defaults)
        XCTAssertFalse(ViewerTextInputPreferences.isEnabled(deviceID: ubuntu, defaults: defaults))
    }
}
