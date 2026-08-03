import XCTest
import VideoPipeline

final class EncodedHEVCPacketTests: XCTestCase {
    func testParsesAnnexBAndFindsParameterSets() throws {
        let packet = try HEVCEncodedPacket(data: annexB([32, 33, 34, 19]), declaredFormat: .annexB)
        XCTAssertEqual(packet.format, .annexB)
        XCTAssertEqual(Set(packet.parameterSets.keys), Set([32, 33, 34]))
        XCTAssertTrue(packet.isKeyframe)
    }

    func testParsesFourByteAVCC() throws {
        let packet = try HEVCEncodedPacket(data: avcc([32, 33, 34, 1]), declaredFormat: .avcc)
        XCTAssertEqual(packet.format, .avcc)
        XCTAssertEqual(packet.nalUnits.count, 4)
        XCTAssertFalse(packet.isKeyframe)
    }

    func testRejectsDeclaredFormatMismatch() {
        XCTAssertThrowsError(try HEVCEncodedPacket(data: annexB([19]), declaredFormat: .avcc))
    }

    func testRejectsMalformedAVCC() {
        XCTAssertThrowsError(try HEVCEncodedPacket(data: Data([0, 0, 0, 8, 0x26, 1])))
    }

    private func nal(_ type: UInt8) -> Data { Data([type << 1, 1, 0x80]) }

    private func annexB(_ types: [UInt8]) -> Data {
        types.reduce(into: Data()) { data, type in
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(nal(type))
        }
    }

    private func avcc(_ types: [UInt8]) -> Data {
        types.reduce(into: Data()) { data, type in
            let unit = nal(type)
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(unit)
        }
    }
}
