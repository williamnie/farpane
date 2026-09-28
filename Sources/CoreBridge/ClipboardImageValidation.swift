import CoreBridgeShim
import Foundation

package let maximumClipboardImageBytes = Int(RDN_MAX_CLIPBOARD_IMAGE_BYTES)
package let maximumClipboardSVGUTF8Bytes = Int(RDN_MAX_CLIPBOARD_SVG_UTF8_BYTES)
let maximumClipboardImageDimension = UInt32(RDN_MAX_CLIPBOARD_IMAGE_DIMENSION)
let maximumClipboardImagePixels = Int(RDN_MAX_CLIPBOARD_IMAGE_PIXELS)

package func clipboardImagePixelCount(width: UInt32, height: UInt32) -> Int? {
    guard width > 0, height > 0, width <= maximumClipboardImageDimension,
        height <= maximumClipboardImageDimension
    else { return nil }
    let (pixels, overflow) = Int(width).multipliedReportingOverflow(by: Int(height))
    guard !overflow, pixels <= maximumClipboardImagePixels else { return nil }
    return pixels
}

func clipboardPNGUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return (UInt32(data[data.startIndex + offset]) << 24)
        | (UInt32(data[data.startIndex + offset + 1]) << 16)
        | (UInt32(data[data.startIndex + offset + 2]) << 8)
        | UInt32(data[data.startIndex + offset + 3])
}

func clipboardPNGChunkIs(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Bool {
    guard offset >= 0, offset <= data.count - bytes.count else { return false }
    return bytes.enumerated().allSatisfy { index, byte in
        data[data.startIndex + offset + index] == byte
    }
}

func clipboardPNGIsCanonical(_ data: Data) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    guard data.count >= 33, clipboardPNGChunkIs(data, at: 0, signature) else { return false }

    var offset = 8
    var hasDimensions = false
    var hasImageData = false
    while true {
        guard let rawLength = clipboardPNGUInt32(data, at: offset) else { return false }
        let length = Int(rawLength)
        let headerEnd = offset.addingReportingOverflow(8)
        guard !headerEnd.overflow else { return false }
        let dataEnd = headerEnd.partialValue.addingReportingOverflow(length)
        guard !dataEnd.overflow else { return false }
        let chunkEnd = dataEnd.partialValue.addingReportingOverflow(4)
        guard !chunkEnd.overflow, chunkEnd.partialValue <= data.count else { return false }

        let typeOffset = offset + 4
        if clipboardPNGChunkIs(data, at: typeOffset, [0x49, 0x48, 0x44, 0x52]) {
            guard offset == 8, length == 13, !hasDimensions else { return false }
            guard let width = clipboardPNGUInt32(data, at: headerEnd.partialValue),
                let height = clipboardPNGUInt32(data, at: headerEnd.partialValue + 4),
                clipboardImagePixelCount(width: width, height: height) != nil
            else { return false }
            let bitDepth = data[data.startIndex + headerEnd.partialValue + 8]
            let colorType = data[data.startIndex + headerEnd.partialValue + 9]
            let validDepth: Bool
            switch colorType {
            case 0: validDepth = [1, 2, 4, 8, 16].contains(bitDepth)
            case 2, 4, 6: validDepth = [8, 16].contains(bitDepth)
            case 3: validDepth = [1, 2, 4, 8].contains(bitDepth)
            default: validDepth = false
            }
            guard validDepth, data[data.startIndex + headerEnd.partialValue + 10] == 0,
                data[data.startIndex + headerEnd.partialValue + 11] == 0,
                data[data.startIndex + headerEnd.partialValue + 12] <= 1
            else { return false }
            hasDimensions = true
        } else if clipboardPNGChunkIs(data, at: typeOffset, [0x49, 0x44, 0x41, 0x54]) {
            guard hasDimensions else { return false }
            if length > 0 { hasImageData = true }
        } else if clipboardPNGChunkIs(data, at: typeOffset, [0x49, 0x45, 0x4e, 0x44]) {
            return length == 0 && hasDimensions && hasImageData
                && chunkEnd.partialValue == data.count
        } else if !hasDimensions {
            return false
        }
        offset = chunkEnd.partialValue
    }
}

func clipboardSVGIsCanonical(_ svg: String) -> Bool {
    guard !svg.isEmpty, !svg.contains("\0") else { return false }
    var remainder = svg.drop(while: {
        $0 == "\u{feff}" || $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
    })
    if remainder.hasPrefix("<?xml") {
        guard let end = remainder.prefix(1024).range(of: "?>") else { return false }
        remainder = remainder[end.upperBound...].drop(while: { $0.isWhitespace })
    }
    guard remainder.range(of: "<!doctype", options: .caseInsensitive) == nil,
        remainder.hasPrefix("<svg")
    else { return false }
    let afterRoot = remainder.dropFirst(4)
    guard let first = afterRoot.first, first == ">" || first.isWhitespace else { return false }
    return afterRoot.contains(">")
}

package func normalizedClipboardImage(_ payload: CoreClipboardImagePayload) -> (
    format: UInt32, data: Data, width: UInt32, height: UInt32
)? {
    switch payload {
    case .rgba(let width, let height, let pixels):
        guard let pixelCount = clipboardImagePixelCount(width: width, height: height) else {
            return nil
        }
        let (expectedBytes, overflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !overflow, expectedBytes == pixels.count, pixels.count <= maximumClipboardImageBytes
        else { return nil }
        return (UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue), pixels, width, height)
    case .png(let data):
        guard data.count <= maximumClipboardImageBytes, clipboardPNGIsCanonical(data) else {
            return nil
        }
        return (UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue), data, 0, 0)
    case .svg(let svg):
        let data = Data(svg.utf8)
        guard data.count <= maximumClipboardSVGUTF8Bytes, clipboardSVGIsCanonical(svg) else {
            return nil
        }
        return (UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue), data, 0, 0)
    }
}
