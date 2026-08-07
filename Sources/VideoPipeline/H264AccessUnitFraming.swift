import Foundation

public enum H264WireFraming: String, Sendable {
    case annexB
    case avcc4
}

public enum H264FramingError: Error, CustomStringConvertible {
    case noNALUnits
    case malformedAnnexB
    case malformedAVCC

    public var description: String {
        switch self {
        case .noNALUnits: return "H.264 access unit contains no NAL units"
        case .malformedAnnexB: return "H.264 Annex-B access unit is malformed"
        case .malformedAVCC: return "H.264 AVCC access unit has an invalid 4-byte NAL length"
        }
    }
}

public struct H264NALUnit: Equatable, Sendable {
    public let type: UInt8
    public let data: Data
}

/// Compressed-byte framing utility for H1c golden vectors. Conversion is
/// intentionally limited to encoded NAL bytes and never touches raw frames.
public struct H264FramingAccessUnit: Equatable, Sendable {
    public let nalUnits: [H264NALUnit]

    public init(data: Data, framing: H264WireFraming) throws {
        let units: [Data]
        switch framing {
        case .annexB: units = try Self.parseAnnexB(data)
        case .avcc4: units = try Self.parseAVCC4(data)
        }
        guard !units.isEmpty else { throw H264FramingError.noNALUnits }
        nalUnits = units.map { H264NALUnit(type: $0[0] & 0x1f, data: $0) }
    }

    public var hasSPS: Bool { nalUnits.contains { $0.type == 7 } }
    public var hasPPS: Bool { nalUnits.contains { $0.type == 8 } }
    public var hasParameterSets: Bool { hasSPS && hasPPS }
    public var isIDR: Bool { nalUnits.contains { $0.type == 5 } }

    public func encoded(as framing: H264WireFraming) -> Data {
        var result = Data()
        for unit in nalUnits {
            switch framing {
            case .annexB:
                result.append(contentsOf: [0, 0, 0, 1])
            case .avcc4:
                var length = UInt32(unit.data.count).bigEndian
                withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            }
            result.append(unit.data)
        }
        return result
    }

    private static func parseAVCC4(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var index = 0
        while index < bytes.count {
            guard bytes.count - index >= 4 else { throw H264FramingError.malformedAVCC }
            let length = Int(UInt32(bytes[index]) << 24
                | UInt32(bytes[index + 1]) << 16
                | UInt32(bytes[index + 2]) << 8
                | UInt32(bytes[index + 3]))
            index += 4
            guard length > 0, length <= bytes.count - index else {
                throw H264FramingError.malformedAVCC
            }
            units.append(Data(bytes[index..<(index + length)]))
            index += length
        }
        return units
    }

    private static func parseAnnexB(_ data: Data) throws -> [Data] {
        let bytes = [UInt8](data)
        func startCodeLength(at index: Int) -> Int? {
            guard index + 2 < bytes.count,
                  bytes[index] == 0,
                  bytes[index + 1] == 0 else { return nil }
            if bytes[index + 2] == 1 { return 3 }
            if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                return 4
            }
            return nil
        }

        guard let firstLength = startCodeLength(at: 0) else {
            throw H264FramingError.malformedAnnexB
        }
        var units: [Data] = []
        var unitStart = firstLength
        var search = unitStart
        while search < bytes.count {
            if let codeLength = startCodeLength(at: search) {
                guard search > unitStart else { throw H264FramingError.malformedAnnexB }
                units.append(Data(bytes[unitStart..<search]))
                unitStart = search + codeLength
                search = unitStart
            } else {
                search += 1
            }
        }
        guard unitStart < bytes.count else { throw H264FramingError.malformedAnnexB }
        units.append(Data(bytes[unitStart..<bytes.count]))
        return units
    }
}
