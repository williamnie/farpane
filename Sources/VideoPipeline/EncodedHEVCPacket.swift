import Foundation

public enum HEVCPacketFormat: String, Codable, Sendable {
    case annexB = "annex-b"
    case avcc
}

public enum HEVCPacketError: Error, CustomStringConvertible {
    case empty
    case unsupportedFraming
    case malformedAVCC
    case declaredFormatMismatch(expected: HEVCPacketFormat, actual: HEVCPacketFormat)

    public var description: String {
        switch self {
        case .empty: return "encoded HEVC packet is empty"
        case .unsupportedFraming: return "encoded HEVC packet is neither Annex-B nor 4-byte AVCC"
        case .malformedAVCC: return "encoded HEVC AVCC packet has an invalid NAL length"
        case .declaredFormatMismatch(let expected, let actual):
            return "core declared \(expected.rawValue), parser found \(actual.rawValue)"
        }
    }
}

public struct HEVCEncodedPacket: Sendable {
    public let format: HEVCPacketFormat
    public let nalUnits: [Data]

    public var isKeyframe: Bool {
        nalUnits.contains { (16...21).contains(Self.nalType($0)) }
    }

    public var parameterSets: [UInt8: Data] {
        Dictionary(uniqueKeysWithValues: nalUnits.compactMap { unit in
            let type = Self.nalType(unit)
            return (32...34).contains(type) ? (type, unit) : nil
        })
    }

    public var accessUnit: HEVCAccessUnit {
        HEVCAccessUnit(nalUnits: nalUnits, isKeyframe: isKeyframe)
    }

    public init(data: Data, declaredFormat: HEVCPacketFormat? = nil) throws {
        guard !data.isEmpty else { throw HEVCPacketError.empty }
        let parsed: (HEVCPacketFormat, [Data])
        if let units = Self.parseAnnexB(data) {
            parsed = (.annexB, units)
        } else if let units = try Self.parseAVCC(data) {
            parsed = (.avcc, units)
        } else {
            throw HEVCPacketError.unsupportedFraming
        }
        if let declaredFormat, declaredFormat != parsed.0 {
            throw HEVCPacketError.declaredFormatMismatch(expected: declaredFormat, actual: parsed.0)
        }
        format = parsed.0
        nalUnits = parsed.1
    }

    public static func nalType(_ nal: Data) -> UInt8 {
        nal.first.map { ($0 >> 1) & 0x3f } ?? 0xff
    }

    private static func parseAnnexB(_ data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, prefix: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append((index, 4)); index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, 3)); index += 3
            } else {
                index += 1
            }
        }
        guard starts.first?.offset == 0 else { return nil }
        let units = starts.enumerated().compactMap { item -> Data? in
            let start = item.element
            let end = item.offset + 1 < starts.count ? starts[item.offset + 1].offset : bytes.count
            let payload = start.offset + start.prefix
            return payload < end ? Data(bytes[payload..<end]) : nil
        }
        return units.isEmpty ? nil : units
    }

    private static func parseAVCC(_ data: Data) throws -> [Data]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        var index = 0
        var units: [Data] = []
        while index + 4 <= bytes.count {
            let length = Int(UInt32(bytes[index]) << 24 |
                             UInt32(bytes[index + 1]) << 16 |
                             UInt32(bytes[index + 2]) << 8 |
                             UInt32(bytes[index + 3]))
            index += 4
            guard length > 0, index + length <= bytes.count else {
                if units.isEmpty { return nil }
                throw HEVCPacketError.malformedAVCC
            }
            units.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        guard index == bytes.count else { throw HEVCPacketError.malformedAVCC }
        return units.isEmpty ? nil : units
    }
}
