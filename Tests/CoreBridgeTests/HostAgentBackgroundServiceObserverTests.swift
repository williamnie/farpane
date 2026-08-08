@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundServiceObserverTests: XCTestCase {
    func testUsesOneImmutableProductLaunchAgentPlistName() {
        XCTAssertEqual(
            HostAgentBackgroundServiceObserver.plistName,
            "io.rustdesknative.viewer.host-agent.plist"
        )
    }

    func testMissingTestBundleServiceFailsClosedWithoutMutation() {
        let launchAgentURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(
                HostAgentBackgroundServiceObserver.plistName,
                isDirectory: false
            )
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchAgentURL.path))

        XCTAssertEqual(
            HostAgentBackgroundServiceObserver.observeRegistrationStatus(),
            .serviceUnavailable
        )
    }

    func testProductObserverIsReadOnlyAndAcceptsNoPathInjection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentBackgroundServiceObserver.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "SMAppService.agent(plistName: plistName).status"
        ))
        XCTAssertFalse(source.contains(".register()"))
        XCTAssertFalse(source.contains(".unregister()"))
        XCTAssertFalse(source.contains("openSystemSettingsLoginItems()"))
        XCTAssertFalse(source.contains("ProcessInfo.processInfo.environment"))
        XCTAssertFalse(source.contains("Bundle.main"))
        XCTAssertFalse(source.contains("URL("))
    }
}
