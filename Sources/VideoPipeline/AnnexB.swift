import Foundation

public enum AnnexBError: Error, CustomStringConvertible {
    case noNALUnits
    case missingParameterSet(String)

    public var description: String {
        switch self {
        case .noNALUnits:
            return "fixture does not contain Annex-B NAL units"
        case .missingParameterSet(let name):
            return "fixture is missing HEVC \(name)"
        }
    }
}

public struct HEVCAccessUnit: Sendable {
    public let nalUnits: [Data]
    public let isKeyframe: Bool

    public init(nalUnits: [Data], isKeyframe: Bool) {
        self.nalUnits = nalUnits
        self.isKeyframe = isKeyframe
    }

    public var avccData: Data {
        var output = Data()
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(nal)
        }
        return output
    }
}

public struct HEVCAnnexBStream: Sendable {
    public let parameterSets: [Data]
    public let accessUnits: [HEVCAccessUnit]

    public init(data: Data) throws {
        let nals = Self.splitNALUnits(data)
        guard !nals.isEmpty else { throw AnnexBError.noNALUnits }

        var vps: Data?
        var sps: Data?
        var pps: Data?
        for nal in nals {
            switch Self.nalType(nal) {
            case 32: if vps == nil { vps = nal }
            case 33: if sps == nil { sps = nal }
            case 34: if pps == nil { pps = nal }
            default: break
            }
        }
        guard let vps else { throw AnnexBError.missingParameterSet("VPS") }
        guard let sps else { throw AnnexBError.missingParameterSet("SPS") }
        guard let pps else { throw AnnexBError.missingParameterSet("PPS") }
        parameterSets = [vps, sps, pps]

        var groups: [[Data]] = []
        var current: [Data] = []
        for nal in nals {
            let type = Self.nalType(nal)
            if type == 35, !current.isEmpty {
                if current.contains(where: Self.isSlice) { groups.append(current) }
                current = []
            }
            current.append(nal)
        }
        if current.contains(where: Self.isSlice) { groups.append(current) }

        // Some encoders omit AUD. In that case first_slice_segment_in_pic_flag marks
        // access-unit boundaries; generated project fixtures always contain AUD.
        if groups.count <= 1 {
            groups = Self.groupWithoutAUD(nals)
        }
        accessUnits = groups.map { group in
            HEVCAccessUnit(
                nalUnits: group,
                isKeyframe: group.contains { (16...21).contains(Self.nalType($0)) }
            )
        }
        guard !accessUnits.isEmpty else { throw AnnexBError.noNALUnits }
    }

    public static func nalType(_ nal: Data) -> UInt8 {
        guard let first = nal.first else { return 0xff }
        return (first >> 1) & 0x3f
    }

    private static func isSlice(_ nal: Data) -> Bool {
        nalType(nal) <= 31
    }

    private static func groupWithoutAUD(_ nals: [Data]) -> [[Data]] {
        var result: [[Data]] = []
        var prefix: [Data] = []
        var current: [Data] = []
        for nal in nals {
            if isSlice(nal), isFirstSlice(nal), current.contains(where: isSlice) {
                result.append(current)
                current = prefix
                prefix.removeAll(keepingCapacity: true)
            }
            if isSlice(nal) {
                if current.isEmpty { current = prefix; prefix.removeAll(keepingCapacity: true) }
                current.append(nal)
            } else if current.contains(where: isSlice) {
                prefix.append(nal)
            } else {
                current.append(nal)
            }
        }
        if current.contains(where: isSlice) { result.append(current + prefix) }
        return result
    }

    private static func isFirstSlice(_ nal: Data) -> Bool {
        guard isSlice(nal), nal.count >= 3 else { return false }
        return (nal[2] & 0x80) != 0
    }

    private static func splitNALUnits(_ data: Data) -> [Data] {
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
        return starts.enumerated().compactMap { item -> Data? in
            let position = item.offset
            let start = item.element
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            let payloadStart = start.offset + start.prefix
            guard payloadStart < end else { return nil }
            return Data(bytes[payloadStart..<end])
        }
    }
}
