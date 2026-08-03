import XCTest
import VideoPipeline

final class AnnexBTests: XCTestCase {
    func testParsesAUDSeparatedAccessUnitsAndParameterSets() throws {
        let data = annexB([
            nal(type: 32, payload: [1]), nal(type: 33, payload: [2]), nal(type: 34, payload: [3]),
            nal(type: 35, payload: [0]), nal(type: 19, payload: [0x80, 4]),
            nal(type: 35, payload: [0]), nal(type: 1, payload: [0x80, 5]),
        ])
        let stream = try HEVCAnnexBStream(data: data)
        XCTAssertEqual(stream.parameterSets.count, 3)
        XCTAssertEqual(stream.accessUnits.count, 2)
        XCTAssertTrue(stream.accessUnits[0].isKeyframe)
        XCTAssertFalse(stream.accessUnits[1].isKeyframe)
        XCTAssertEqual(stream.accessUnits[0].avccData.prefix(4), Data([0, 0, 0, 3]))
    }

    func testRejectsMissingParameterSet() {
        XCTAssertThrowsError(try HEVCAnnexBStream(data: annexB([nal(type: 32, payload: [1])])))
    }

    private func nal(type: UInt8, payload: [UInt8]) -> Data {
        Data([type << 1, 1] + payload)
    }

    private func annexB(_ nals: [Data]) -> Data {
        nals.reduce(into: Data()) { result, nal in
            result.append(contentsOf: [0, 0, 0, 1])
            result.append(nal)
        }
    }
}
