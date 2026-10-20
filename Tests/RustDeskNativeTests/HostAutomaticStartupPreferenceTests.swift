import Foundation
import XCTest

@testable import RustDeskNative

final class HostAutomaticStartupPreferenceTests: XCTestCase {
    func testExplicitHostChoiceSurvivesRestartAndFailedOrCancelledChangesPreserveIt() throws {
        let suite = "farpane-startup-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = HostAutomaticStartupPreference(defaults: defaults)
        XCTAssertTrue(preference.isAllowed)
        preference.record(.disable)
        XCTAssertFalse(preference.isAllowed)
        let reopened = HostAutomaticStartupPreference(defaults: defaults)
        XCTAssertFalse(reopened.isAllowed)
        reopened.record(.noChange)
        reopened.record(.invalidCompletion)
        XCTAssertFalse(reopened.isAllowed)
        reopened.record(.enableAndRefresh)
        XCTAssertTrue(HostAutomaticStartupPreference(defaults: defaults).isAllowed)
    }
}
