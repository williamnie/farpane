import CoreBridge
import XCTest

final class ViewerDisplaySelectionTests: XCTestCase {
    func testRequestRequiresPositiveExactIdentity() throws {
        let request = try XCTUnwrap(CoreDisplaySelectionRequest(
            connectionEpoch: 7,
            commandID: 11,
            catalogRevision: 3,
            displayIndex: 1
        ))
        XCTAssertEqual(request.connectionEpoch, 7)
        XCTAssertEqual(request.commandID, 11)
        XCTAssertEqual(request.catalogRevision, 3)
        XCTAssertEqual(request.displayIndex, 1)

        XCTAssertNil(CoreDisplaySelectionRequest(
            connectionEpoch: 0,
            commandID: 11,
            catalogRevision: 3,
            displayIndex: 1
        ))
        XCTAssertNil(CoreDisplaySelectionRequest(
            connectionEpoch: 7,
            commandID: 0,
            catalogRevision: 3,
            displayIndex: 1
        ))
        XCTAssertNil(CoreDisplaySelectionRequest(
            connectionEpoch: 7,
            commandID: 11,
            catalogRevision: 0,
            displayIndex: 1
        ))
    }

    func testTerminalEventRequiresCanonicalResultFailurePair() throws {
        let selected = try XCTUnwrap(CoreDisplaySelectionEvent(
            connectionEpoch: 7,
            commandID: 11,
            catalogRevision: 3,
            displayIndex: 1,
            result: .selected,
            failure: .none
        ))
        XCTAssertEqual(selected.result, .selected)
        XCTAssertEqual(selected.failure, .none)

        XCTAssertNotNil(CoreDisplaySelectionEvent(
            connectionEpoch: 7,
            commandID: 12,
            catalogRevision: 3,
            displayIndex: 1,
            result: .alreadySelected,
            failure: .none
        ))
        XCTAssertNotNil(CoreDisplaySelectionEvent(
            connectionEpoch: 7,
            commandID: 13,
            catalogRevision: 3,
            displayIndex: 1,
            result: .failed,
            failure: .catalogChanged
        ))
        XCTAssertNil(CoreDisplaySelectionEvent(
            connectionEpoch: 7,
            commandID: 14,
            catalogRevision: 3,
            displayIndex: 1,
            result: .selected,
            failure: .connectionClosed
        ))
        XCTAssertNil(CoreDisplaySelectionEvent(
            connectionEpoch: 7,
            commandID: 15,
            catalogRevision: 3,
            displayIndex: 1,
            result: .failed,
            failure: .none
        ))
    }
}
