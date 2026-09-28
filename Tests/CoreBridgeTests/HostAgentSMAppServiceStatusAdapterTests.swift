import ServiceManagement
import XCTest

@testable import CoreBridge

final class HostAgentSMAppServiceStatusAdapterTests: XCTestCase {
    func testMapsEveryKnownMacOS13ServiceStatusSemantically() {
        let expected: [(SMAppService.Status, HostAgentBackgroundRegistrationStatus)] = [
            (.notRegistered, .notRegistered), (.enabled, .enabled),
            (.requiresApproval, .requiresApproval), (.notFound, .serviceUnavailable),
        ]

        for (source, registration) in expected {
            XCTAssertEqual(HostAgentSMAppServiceStatusAdapter.map(source), registration)
        }
    }

}
