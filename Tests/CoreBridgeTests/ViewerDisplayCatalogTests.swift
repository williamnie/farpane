import CoreBridge
import XCTest

final class ViewerDisplayCatalogTests: XCTestCase {
    func testAvailableCatalogRequiresContiguousEntriesAndSelectableSelection() throws {
        let entries = [
            try XCTUnwrap(CoreDisplayCatalogEntry(
                displayIndex: 0,
                x: 0,
                y: 0,
                width: 1920,
                height: 1080,
                online: true,
                scale: 2,
                name: "Built-in"
            )),
            try XCTUnwrap(CoreDisplayCatalogEntry(
                displayIndex: 1,
                x: 1920,
                y: 0,
                width: 2560,
                height: 1440,
                online: true,
                scale: 1,
                name: "Studio"
            )),
        ]
        let event = try XCTUnwrap(CoreDisplayCatalogEvent(
            connectionEpoch: 7,
            catalogRevision: 3,
            status: .available,
            selectedDisplayIndex: 1,
            entries: entries
        ))

        XCTAssertEqual(event.connectionEpoch, 7)
        XCTAssertEqual(event.catalogRevision, 3)
        XCTAssertEqual(event.selectedDisplayIndex, 1)
        XCTAssertEqual(event.entries, entries)

        XCTAssertNil(CoreDisplayCatalogEvent(
            connectionEpoch: 7,
            catalogRevision: 3,
            status: .available,
            selectedDisplayIndex: 2,
            entries: entries
        ))
        XCTAssertNil(CoreDisplayCatalogEvent(
            connectionEpoch: 7,
            catalogRevision: 3,
            status: .available,
            selectedDisplayIndex: nil,
            entries: [entries[1]]
        ))
    }

    func testCatalogRejectsMalformedNamesGeometryScaleAndUnavailablePayload() throws {
        XCTAssertNil(CoreDisplayCatalogEntry(
            displayIndex: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            online: true,
            scale: .nan,
            name: "Main"
        ))
        XCTAssertNil(CoreDisplayCatalogEntry(
            displayIndex: 0,
            x: 0,
            y: 0,
            width: 0,
            height: 1080,
            online: true,
            scale: 1,
            name: "Main"
        ))
        XCTAssertNil(CoreDisplayCatalogEntry(
            displayIndex: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            online: true,
            scale: 1,
            name: "bad\nname"
        ))
        let entry = try XCTUnwrap(CoreDisplayCatalogEntry(
            displayIndex: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            online: true,
            scale: 1,
            name: "Main"
        ))
        XCTAssertNil(CoreDisplayCatalogEvent(
            connectionEpoch: 7,
            catalogRevision: 4,
            status: .unavailable,
            selectedDisplayIndex: nil,
            entries: [entry]
        ))
        XCTAssertNotNil(CoreDisplayCatalogEvent(
            connectionEpoch: 7,
            catalogRevision: 4,
            status: .unavailable,
            selectedDisplayIndex: nil,
            entries: []
        ))
    }

    func testProjectionAcceptsOnlyExactCurrentCatalogFrameTuple() throws {
        let entry = try XCTUnwrap(CoreDisplayCatalogEntry(
            displayIndex: 0,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            online: true,
            scale: 2,
            name: "Main"
        ))
        let available = try XCTUnwrap(CoreDisplayCatalogEvent(
            connectionEpoch: 11,
            catalogRevision: 5,
            status: .available,
            selectedDisplayIndex: 0,
            entries: [entry]
        ))
        var projection = CoreDisplayCatalogProjectionState()
        XCTAssertTrue(projection.observe(available))
        XCTAssertTrue(projection.acceptsFrame(
            connectionEpoch: 11,
            catalogRevision: 5,
            displayIndex: 0
        ))
        XCTAssertFalse(projection.acceptsFrame(
            connectionEpoch: 10,
            catalogRevision: 5,
            displayIndex: 0
        ))
        XCTAssertFalse(projection.acceptsFrame(
            connectionEpoch: 11,
            catalogRevision: 4,
            displayIndex: 0
        ))
        XCTAssertFalse(projection.acceptsFrame(
            connectionEpoch: 11,
            catalogRevision: 5,
            displayIndex: 1
        ))
        let changedEntry = try XCTUnwrap(CoreDisplayCatalogEntry(
            displayIndex: 0,
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            online: true,
            scale: 2,
            name: "Main"
        ))
        let illegalSameRevisionChange = try XCTUnwrap(CoreDisplayCatalogEvent(
            connectionEpoch: 11,
            catalogRevision: 5,
            status: .available,
            selectedDisplayIndex: 0,
            entries: [changedEntry]
        ))
        XCTAssertFalse(projection.observe(illegalSameRevisionChange))
        XCTAssertTrue(projection.acceptsFrame(
            connectionEpoch: 11,
            catalogRevision: 5,
            displayIndex: 0
        ))

        let unavailable = try XCTUnwrap(CoreDisplayCatalogEvent(
            connectionEpoch: 11,
            catalogRevision: 6,
            status: .unavailable,
            selectedDisplayIndex: nil,
            entries: []
        ))
        XCTAssertTrue(projection.observe(unavailable))
        XCTAssertFalse(projection.acceptsFrame(
            connectionEpoch: 11,
            catalogRevision: 6,
            displayIndex: 0
        ))
        projection.stop()
        XCTAssertFalse(projection.observe(available))
    }
}
