import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentBackgroundRegistrationSheetDriverTests: XCTestCase {
    func testMapsEveryPromptResponseToOneMatchingTypedIntent() {
        let expected:
            [(
                HostAgentBackgroundRegistrationUXPromptKind, Bool,
                HostAgentBackgroundRegistrationUXIntent
            )] = [
                (.backgroundPersistence, true, .confirmBackgroundRegistration),
                (.backgroundPersistence, false, .cancelBackgroundRegistration),
                (.loginItemsApproval, true, .confirmApprovalNavigation),
                (.loginItemsApproval, false, .cancelApprovalNavigation),
            ]

        for (kind, confirmed, intent) in expected {
            XCTAssertEqual(
                HostAgentBackgroundRegistrationSheetResponsePolicy.intent(
                    promptKind: kind, confirmed: confirmed), intent)
        }
    }

}
