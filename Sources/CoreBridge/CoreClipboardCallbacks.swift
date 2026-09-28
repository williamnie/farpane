import CoreBridgeShim
import Foundation

let clipboardTextCallback: RDNClipboardTextCallback = { context, utf8, length in
    guard let context, let utf8, length > 0, length <= Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES) else {
        return
    }
    let data = Data(bytes: utf8, count: length)
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverClipboardText(text)
}

func copiedOptionalClipboardUTF8(_ utf8: UnsafePointer<UInt8>?, length: Int, maximum: Int) -> (
    valid: Bool, text: String?
) {
    guard let utf8 else { return (length == 0, nil) }
    guard length > 0, length <= maximum else { return (false, nil) }
    let data = Data(bytes: utf8, count: length)
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
        return (false, nil)
    }
    return (true, text)
}

func optionalClipboardUTF8Data(_ text: String?, maximum: Int) -> (valid: Bool, data: Data?) {
    guard let text else { return (true, nil) }
    let data = Data(text.utf8)
    guard !data.isEmpty, data.count <= maximum, !text.contains("\0") else { return (false, nil) }
    return (true, data)
}

let clipboardRichTextCallback: RDNClipboardRichTextCallback = { context, payloadPointer in
    guard let context, let payloadPointer else { return }
    let raw = payloadPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION else { return }
    let plain = copiedOptionalClipboardUTF8(
        raw.plain_utf8, length: raw.plain_length, maximum: Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES))
    let rtf = copiedOptionalClipboardUTF8(
        raw.rtf_utf8, length: raw.rtf_length, maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES))
    let html = copiedOptionalClipboardUTF8(
        raw.html_utf8, length: raw.html_length, maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES)
    )
    guard plain.valid, rtf.valid, html.valid, rtf.text != nil || html.text != nil else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverClipboardRichText(
        CoreClipboardRichTextPayload(plainText: plain.text, rtf: rtf.text, html: html.text))
}

let clipboardImageCallback: RDNClipboardImageCallback = { context, payloadPointer in
    guard let context, let payloadPointer else { return }
    let raw = payloadPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, let bytes = raw.data, raw.length > 0 else { return }
    switch raw.format {
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue):
        guard let pixelCount = clipboardImagePixelCount(width: raw.width, height: raw.height),
            raw.length == pixelCount * 4, raw.length <= maximumClipboardImageBytes
        else { return }
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue):
        guard raw.width == 0, raw.height == 0, raw.length <= maximumClipboardImageBytes else {
            return
        }
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue):
        guard raw.width == 0, raw.height == 0, raw.length <= maximumClipboardSVGUTF8Bytes else {
            return
        }
    default: return
    }
    let data = Data(bytes: bytes, count: raw.length)
    let candidate: CoreClipboardImagePayload
    switch raw.format {
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue):
        candidate = .rgba(width: raw.width, height: raw.height, pixels: data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue): candidate = .png(data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue):
        guard let svg = String(data: data, encoding: .utf8) else { return }
        candidate = .svg(svg)
    default: return
    }
    guard let normalized = normalizedClipboardImage(candidate) else { return }
    let payload: CoreClipboardImagePayload
    switch normalized.format {
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue):
        payload = .rgba(width: normalized.width, height: normalized.height, pixels: normalized.data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue): payload = .png(normalized.data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue):
        guard let svg = String(data: normalized.data, encoding: .utf8) else { return }
        payload = .svg(svg)
    default: return
    }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverClipboardImage(payload)
}
