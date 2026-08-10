import AppKit
import CoreBridge
import Foundation

/// The only native Viewer owner allowed to touch NSPasteboard. Rust receives
/// and sends bounded semantic clipboard payloads only; this adapter binds them
/// to one current App session and suppresses its own writes from the poller.
final class ViewerPasteboardOwner {
    typealias SendText = (String) -> Int32
    typealias SendRichText = (CoreClipboardRichTextPayload) -> Int32

    private enum LocalRichTextRead {
        case absent
        case invalid
        case payload(CoreClipboardRichTextPayload)
    }

    private let pasteboard: NSPasteboard
    private var pollingState = ViewerClipboardPollingState()
    private var timer: Timer?
    private var sessionEpoch: UInt64?
    private var receiveTextEnabled = false
    private var sendTextEnabled = false
    private var receiveRichTextEnabled = false
    private var sendRichTextEnabled = false
    private var active = false
    private var sendText: SendText?
    private var sendRichText: SendRichText?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func begin(
        sessionEpoch: UInt64,
        receiveTextEnabled: Bool,
        sendTextEnabled: Bool,
        receiveRichTextEnabled: Bool,
        sendRichTextEnabled: Bool,
        sendText: @escaping SendText,
        sendRichText: @escaping SendRichText
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
        self.sendText = sendText
        self.sendRichText = sendRichText
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
        sendText = nil
        sendRichText = nil
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
        sendTextEnabled || sendRichTextEnabled
    }

    private func sendLocalPasteboard() {
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
}
