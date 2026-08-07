import Foundation
import XCTest
@testable import VideoPipeline

private struct H264FramingFixture: Decodable {
    let name: String
    let source: String
    let nalHex: [String]
    let avcc4Hex: String
    let annexBHex: String
}

final class H264AccessUnitFramingTests: XCTestCase {
    func testProvisionalAVCCAndAnnexBGoldenVectorsAreEquivalent() throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "h264-framing-vectors",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let fixture = try JSONDecoder().decode(
            H264FramingFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        XCTAssertEqual(fixture.name, "provisional-h264-idr")
        XCTAssertTrue(fixture.source.contains("official RustDesk"))

        let avcc = try H264FramingAccessUnit(
            data: try Data(hex: fixture.avcc4Hex),
            framing: .avcc4
        )
        let annexB = try H264FramingAccessUnit(
            data: try Data(hex: fixture.annexBHex),
            framing: .annexB
        )
        XCTAssertEqual(avcc, annexB)
        XCTAssertEqual(avcc.nalUnits.map(\.data), try fixture.nalHex.map(Data.init(hex:)))
        XCTAssertEqual(avcc.nalUnits.map(\.type), [7, 8, 5])
        XCTAssertTrue(avcc.hasParameterSets)
        XCTAssertTrue(avcc.isIDR)
        XCTAssertEqual(avcc.encoded(as: .avcc4), try Data(hex: fixture.avcc4Hex))
        XCTAssertEqual(avcc.encoded(as: .annexB), annexB.encoded(as: .annexB))
    }

    func testFramingParserFailsClosedOnTruncationAndEmptyNALs() {
        XCTAssertThrowsError(try H264FramingAccessUnit(
            data: Data([0, 0, 0, 4, 0x65, 0x01]),
            framing: .avcc4
        ))
        XCTAssertThrowsError(try H264FramingAccessUnit(
            data: Data([0, 0, 0, 0]),
            framing: .avcc4
        ))
        XCTAssertThrowsError(try H264FramingAccessUnit(
            data: Data([0, 0, 0, 1, 0, 0, 1, 0x65]),
            framing: .annexB
        ))
        XCTAssertThrowsError(try H264FramingAccessUnit(
            data: Data([0x65, 0x01]),
            framing: .annexB
        ))
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
