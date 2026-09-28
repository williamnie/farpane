import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentBackgroundServiceObserverTests: XCTestCase {
    func testUsesOneImmutableProductLaunchAgentPlistName() {
        XCTAssertEqual(
            HostAgentBackgroundServiceObserver.plistName,
            "io.rustdesknative.viewer.host-agent.plist")
    }

    func testMissingTestBundleServiceFailsClosedWithoutMutation() {
        let launchAgentURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchAgents", isDirectory: true
        ).appendingPathComponent(HostAgentBackgroundServiceObserver.plistName, isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgentURL.path))

        XCTAssertEqual(
            HostAgentBackgroundServiceObserver.observeRegistrationStatus(), .serviceUnavailable)
    }

}
