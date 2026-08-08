@testable import CoreBridge
import ServiceManagement
import XCTest

final class HostAgentSMAppServiceStatusAdapterTests: XCTestCase {
    func testMapsEveryKnownMacOS13ServiceStatusSemantically() {
        let expected: [(
            SMAppService.Status,
            HostAgentBackgroundRegistrationStatus
        )] = [
            (.notRegistered, .notRegistered),
            (.enabled, .enabled),
            (.requiresApproval, .requiresApproval),
            (.notFound, .serviceUnavailable),
        ]

        for (source, registration) in expected {
            XCTAssertEqual(
                HostAgentSMAppServiceStatusAdapter.map(source),
                registration
            )
        }
    }

    func testAdapterIsReadOnlyAndFailsClosedForFutureStatusValues() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot.appendingPathComponent(
            "Sources/CoreBridge/HostAgentSMAppServiceStatusAdapter.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("@unknown default:"))
        XCTAssertTrue(source.contains("return .serviceUnavailable"))
        XCTAssertFalse(source.contains("SMAppService.agent("))
        XCTAssertFalse(source.contains(".register()"))
        XCTAssertFalse(source.contains(".unregister()"))
        XCTAssertFalse(source.contains("openSystemSettingsLoginItems()"))
    }
}
