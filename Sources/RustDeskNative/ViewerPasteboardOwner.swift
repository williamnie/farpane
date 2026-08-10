import AppKit
import CoreBridge
import Foundation
import ImageIO

/// The only native Viewer owner allowed to touch NSPasteboard. Rust receives
/// and sends bounded semantic clipboard payloads only; this adapter binds them
/// to one current App session and suppresses its own writes from the poller.
final class ViewerPasteboardOwner {
    typealias SendText = (String) -> Int32
    typealias SendRichText = (CoreClipboardRichTextPayload) -> Int32
    typealias SendImage = (CoreClipboardImagePayload) -> Int32

    private static let svgPasteboardType =
        NSPasteboard.PasteboardType("public.svg-image")

    private enum LocalRichTextRead {
        case absent
        case invalid
        case payload(CoreClipboardRichTextPayload)
    }

    private enum LocalImageRead {
        case absent
        case invalid
        case payload(CoreClipboardImagePayload)
    }

    private let pasteboard: NSPasteboard
    private var pollingState = ViewerClipboardPollingState()
    private var timer: Timer?
    private var sessionEpoch: UInt64?
    private var receiveTextEnabled = false
    private var sendTextEnabled = false
    private var receiveRichTextEnabled = false
    private var sendRichTextEnabled = false
    private var receiveImageEnabled = false
    private var sendImageEnabled = false
    private var active = false
    private var sendText: SendText?
    private var sendRichText: SendRichText?
    private var sendImage: SendImage?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func begin(
        sessionEpoch: UInt64,
        receiveTextEnabled: Bool,
        sendTextEnabled: Bool,
        receiveRichTextEnabled: Bool,
        sendRichTextEnabled: Bool,
        receiveImageEnabled: Bool,
        sendImageEnabled: Bool,
        sendText: @escaping SendText,
        sendRichText: @escaping SendRichText,
        sendImage: @escaping SendImage
    ) -> Bool {
        guard
            Thread.isMainThread,
            sessionEpoch > 0,
            self.sessionEpoch == nil
        else { return false }
        self.sessionEpoch = sessionEpoch
        self.receiveTextEnabled = receiveTextEnabled
        self.sendTextEnabled = sendTextEnabled
        self.receiveRichTextEnabled = receiveRichTextEnabled
        self.sendRichTextEnabled = sendRichTextEnabled
        self.receiveImageEnabled = receiveImageEnabled
        self.sendImageEnabled = sendImageEnabled
        self.sendText = sendText
        self.sendRichText = sendRichText
        self.sendImage = sendImage
        return true
    }

    func activate(sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            !active
        else { return }
        active = true
        guard sendsAnyFormat else { return }
        guard let delay = pollingState.begin(
            sessionEpoch: sessionEpoch,
            currentChangeCount: pasteboard.changeCount
        ) else {
            active = false
            return
        }
        schedule(afterMilliseconds: delay, sessionEpoch: sessionEpoch)
    }

    func receiveRemoteText(_ text: String, sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            active,
            receiveTextEnabled,
            ViewerClipboardTextPolicy.accepts(text)
        else { return }

        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return }
        commitRemoteItem(item, sessionEpoch: sessionEpoch)
    }

    func receiveRemoteRichText(
        _ payload: CoreClipboardRichTextPayload,
        sessionEpoch: UInt64
    ) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            active,
            receiveRichTextEnabled,
            ViewerClipboardRichTextPolicy.accepts(payload)
        else { return }

        let item = NSPasteboardItem()
        if let plainText = payload.plainText,
           !item.setString(plainText, forType: .string) {
            return
        }
        if let rtf = payload.rtf,
           !item.setData(Data(rtf.utf8), forType: .rtf) {
            return
        }
        if let html = payload.html,
           !item.setData(Data(html.utf8), forType: .html) {
            return
        }
        commitRemoteItem(item, sessionEpoch: sessionEpoch)
    }

    func receiveRemoteImage(
        _ payload: CoreClipboardImagePayload,
        sessionEpoch: UInt64
    ) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            active,
            receiveImageEnabled,
            ViewerClipboardImagePolicy.accepts(payload)
        else { return }

        let item = NSPasteboardItem()
        switch payload {
        case let .rgba(width, height, pixels):
            guard
                let png = Self.pngData(
                    rgba: pixels,
                    width: Int(width),
                    height: Int(height)
                ),
                item.setData(png, forType: .png)
            else { return }
        case let .png(data):
            guard item.setData(data, forType: .png) else { return }
        case let .svg(svg):
            guard item.setData(
                Data(svg.utf8),
                forType: Self.svgPasteboardType
            ) else { return }
        }
        commitRemoteItem(item, sessionEpoch: sessionEpoch)
    }

    private func commitRemoteItem(_ item: NSPasteboardItem, sessionEpoch: UInt64) {
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return }

        guard sendsAnyFormat, let delay = pollingState.observeOwnedWrite(
            sessionEpoch: sessionEpoch,
            resultingChangeCount: pasteboard.changeCount
        ) else { return }
        timer?.invalidate()
        schedule(afterMilliseconds: delay, sessionEpoch: sessionEpoch)
    }

    func suspend(sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            active
        else { return }
        active = false
        timer?.invalidate()
        timer = nil
        if sendsAnyFormat {
            _ = pollingState.stop(sessionEpoch: sessionEpoch)
        }
    }

    func stop(sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch
        else { return }
        suspend(sessionEpoch: sessionEpoch)
        self.sessionEpoch = nil
        receiveTextEnabled = false
        sendTextEnabled = false
        receiveRichTextEnabled = false
        sendRichTextEnabled = false
        receiveImageEnabled = false
        sendImageEnabled = false
        sendText = nil
        sendRichText = nil
        sendImage = nil
    }

    private func schedule(afterMilliseconds delay: UInt64, sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            active,
            self.sessionEpoch == sessionEpoch
        else { return }
        let timer = Timer(timeInterval: Double(delay) / 1_000, repeats: false) {
            [weak self] _ in
            self?.poll(sessionEpoch: sessionEpoch)
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func poll(sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            active,
            sendsAnyFormat
        else { return }

        let changeCount = pasteboard.changeCount
        let decision = pollingState.observeChange(
            sessionEpoch: sessionEpoch,
            changeCount: changeCount
        )
        if decision.didChange {
            sendLocalPasteboard()
        }
        if let delay = decision.nextDelayMilliseconds {
            schedule(afterMilliseconds: delay, sessionEpoch: sessionEpoch)
        }
    }

    private var sendsAnyFormat: Bool {
        sendTextEnabled || sendRichTextEnabled || sendImageEnabled
    }

    private func sendLocalPasteboard() {
        if sendImageEnabled {
            switch readLocalImage() {
            case let .payload(payload):
                _ = sendImage?(payload)
                return
            case .invalid:
                return
            case .absent:
                break
            }
        }
        if sendRichTextEnabled {
            switch readLocalRichText() {
            case let .payload(payload):
                _ = sendRichText?(payload)
                return
            case .invalid:
                return
            case .absent:
                break
            }
        }
        guard
            sendTextEnabled,
            let text = boundedUTF8String(
                forType: .string,
                maximumBytes: ViewerClipboardTextPolicy.maximumUTF8Bytes
            ),
            ViewerClipboardTextPolicy.accepts(text)
        else { return }
        _ = sendText?(text)
    }

    private func readLocalImage() -> LocalImageRead {
        let types = pasteboard.types ?? []
        let hasSVG = types.contains(Self.svgPasteboardType)
        let hasPNG = types.contains(.png)
        let hasTIFF = types.contains(.tiff)
        guard hasSVG || hasPNG || hasTIFF else { return .absent }
        guard pasteboard.pasteboardItems?.count == 1 else { return .invalid }

        if hasSVG {
            guard
                let data = boundedData(
                    forType: Self.svgPasteboardType,
                    maximumBytes: ViewerClipboardImagePolicy.maximumSVGUTF8Bytes
                ),
                let svg = String(data: data, encoding: .utf8)
            else { return .invalid }
            let payload = CoreClipboardImagePayload.svg(svg)
            return ViewerClipboardImagePolicy.accepts(payload)
                ? .payload(payload)
                : .invalid
        }

        if hasPNG {
            guard let data = boundedData(
                forType: .png,
                maximumBytes: ViewerClipboardImagePolicy.maximumImageBytes
            ) else { return .invalid }
            let payload = CoreClipboardImagePayload.png(data)
            return ViewerClipboardImagePolicy.accepts(payload)
                ? .payload(payload)
                : .invalid
        }

        guard
            let tiff = boundedData(
                forType: .tiff,
                maximumBytes: ViewerClipboardImagePolicy.maximumImageBytes
            ),
            let dimensions = Self.imageDimensions(in: tiff),
            ViewerClipboardImagePolicy.acceptsDimensions(
                width: dimensions.width,
                height: dimensions.height
            ),
            let bitmap = NSBitmapImageRep(data: tiff),
            bitmap.pixelsWide == dimensions.width,
            bitmap.pixelsHigh == dimensions.height,
            let png = bitmap.representation(using: .png, properties: [:])
        else { return .invalid }
        let payload = CoreClipboardImagePayload.png(png)
        return ViewerClipboardImagePolicy.accepts(payload)
            ? .payload(payload)
            : .invalid
    }

    private func readLocalRichText() -> LocalRichTextRead {
        let types = pasteboard.types ?? []
        let hasRTF = types.contains(.rtf)
        let hasHTML = types.contains(.html)
        guard hasRTF || hasHTML else { return .absent }
        guard pasteboard.pasteboardItems?.count == 1 else { return .invalid }

        var plainText: String?
        if types.contains(.string) {
            guard let value = boundedUTF8String(
                forType: .string,
                maximumBytes: ViewerClipboardTextPolicy.maximumUTF8Bytes
            ), ViewerClipboardTextPolicy.accepts(value) else { return .invalid }
            plainText = value
        }

        var rtf: String?
        if hasRTF {
            guard let value = boundedUTF8String(
                forType: .rtf,
                maximumBytes: ViewerClipboardRichTextPolicy.maximumRichTextUTF8Bytes
            ) else { return .invalid }
            rtf = value
        }

        var html: String?
        if hasHTML {
            guard let value = boundedUTF8String(
                forType: .html,
                maximumBytes: ViewerClipboardRichTextPolicy.maximumRichTextUTF8Bytes
            ) else { return .invalid }
            html = value
        }

        let payload = CoreClipboardRichTextPayload(
            plainText: plainText,
            rtf: rtf,
            html: html
        )
        return ViewerClipboardRichTextPolicy.accepts(payload)
            ? .payload(payload)
            : .invalid
    }

    private func boundedUTF8String(
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) -> String? {
        guard
            let data = pasteboard.data(forType: type),
            !data.isEmpty,
            data.count <= maximumBytes,
            let value = String(data: data, encoding: .utf8),
            !value.contains("\0")
        else { return nil }
        return value
    }

    private func boundedData(
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) -> Data? {
        guard
            let data = pasteboard.data(forType: type),
            !data.isEmpty,
            data.count <= maximumBytes
        else { return nil }
        return data
    }

    private static func pngData(
        rgba pixels: Data,
        width: Int,
        height: Int
    ) -> Data? {
        guard
            ViewerClipboardImagePolicy.accepts(.rgba(
                width: UInt32(width),
                height: UInt32(height),
                pixels: pixels
            )),
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ),
            let destination = bitmap.bitmapData
        else { return nil }
        pixels.copyBytes(to: destination, count: pixels.count)
        guard
            let png = bitmap.representation(using: .png, properties: [:]),
            ViewerClipboardImagePolicy.accepts(.png(png))
        else { return nil }
        return png
    }

    private static func imageDimensions(in data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetCount(source) == 1,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                options
            ) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        return (width, height)
    }
}
