import Foundation

package enum ViewerClipboardTextPolicy {
    package static let maximumUTF8Bytes = 64 * 1024

    package static func accepts(_ text: String) -> Bool {
        !text.isEmpty
            && !text.contains("\0")
            && text.utf8.count <= maximumUTF8Bytes
    }
}

package enum ViewerClipboardRichTextPolicy {
    package static let maximumRichTextUTF8Bytes = 1024 * 1024

    package static func accepts(_ payload: CoreClipboardRichTextPayload) -> Bool {
        guard payload.rtf != nil || payload.html != nil else { return false }
        if let plainText = payload.plainText,
           !ViewerClipboardTextPolicy.accepts(plainText) {
            return false
        }
        return acceptsRichRepresentation(payload.rtf)
            && acceptsRichRepresentation(payload.html)
    }

    private static func acceptsRichRepresentation(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && !value.contains("\0")
            && value.utf8.count <= maximumRichTextUTF8Bytes
    }
}

package enum ViewerClipboardImagePolicy {
    package static let maximumImageBytes = maximumClipboardImageBytes
    package static let maximumSVGUTF8Bytes = maximumClipboardSVGUTF8Bytes

    package static func accepts(_ payload: CoreClipboardImagePayload) -> Bool {
        normalizedClipboardImage(payload) != nil
    }

    package static func acceptsDimensions(width: Int, height: Int) -> Bool {
        guard
            width > 0,
            height > 0,
            width <= Int(UInt32.max),
            height <= Int(UInt32.max)
        else { return false }
        return clipboardImagePixelCount(
            width: UInt32(width),
            height: UInt32(height)
        ) != nil
    }
}

package struct ViewerClipboardChangeDecision: Equatable, Sendable {
    package let didChange: Bool
    package let nextDelayMilliseconds: UInt64?
}

package struct ViewerClipboardPollDecision: Equatable, Sendable {
    package let textToSend: String?
    package let nextDelayMilliseconds: UInt64?
}

/// Pure state for the AppKit pasteboard fallback poller. The product adapter
/// owns NSPasteboard and timers; this type only enforces session binding,
/// bounded text and dynamic backoff.
package struct ViewerClipboardPollingState: Sendable {
    package static let productDelaysMilliseconds: [UInt64] = [
        125, 250, 500, 1_000, 2_000, 4_000,
    ]

    private var sessionEpoch: UInt64?
    private var observedChangeCount: Int?
    private var delayIndex = 0

    package init() {}

    package mutating func begin(
        sessionEpoch: UInt64,
        currentChangeCount: Int
    ) -> UInt64? {
        guard sessionEpoch > 0, self.sessionEpoch == nil else { return nil }
        self.sessionEpoch = sessionEpoch
        observedChangeCount = currentChangeCount
        delayIndex = 0
        return Self.productDelaysMilliseconds[delayIndex]
    }

    package mutating func observePoll(
        sessionEpoch: UInt64,
        changeCount: Int,
        text: @autoclosure () -> String?
    ) -> ViewerClipboardPollDecision {
        let change = observeChange(
            sessionEpoch: sessionEpoch,
            changeCount: changeCount
        )
        guard change.nextDelayMilliseconds != nil else {
            return ViewerClipboardPollDecision(
                textToSend: nil,
                nextDelayMilliseconds: nil
            )
        }
        guard change.didChange else {
            return ViewerClipboardPollDecision(
                textToSend: nil,
                nextDelayMilliseconds: change.nextDelayMilliseconds
            )
        }
        return ViewerClipboardPollDecision(
            textToSend: text().flatMap {
                ViewerClipboardTextPolicy.accepts($0) ? $0 : nil
            },
            nextDelayMilliseconds: change.nextDelayMilliseconds
        )
    }

    package mutating func observeChange(
        sessionEpoch: UInt64,
        changeCount: Int
    ) -> ViewerClipboardChangeDecision {
        guard self.sessionEpoch == sessionEpoch else {
            return ViewerClipboardChangeDecision(
                didChange: false,
                nextDelayMilliseconds: nil
            )
        }

        if observedChangeCount == changeCount {
            delayIndex = min(
                delayIndex + 1,
                Self.productDelaysMilliseconds.count - 1
            )
            return ViewerClipboardChangeDecision(
                didChange: false,
                nextDelayMilliseconds: Self.productDelaysMilliseconds[delayIndex]
            )
        }

        observedChangeCount = changeCount
        delayIndex = 0
        return ViewerClipboardChangeDecision(
            didChange: true,
            nextDelayMilliseconds: Self.productDelaysMilliseconds[delayIndex]
        )
    }

    package mutating func observeOwnedWrite(
        sessionEpoch: UInt64,
        resultingChangeCount: Int
    ) -> UInt64? {
        guard self.sessionEpoch == sessionEpoch else { return nil }
        observedChangeCount = resultingChangeCount
        delayIndex = 0
        return Self.productDelaysMilliseconds[delayIndex]
    }

    @discardableResult
    package mutating func stop(sessionEpoch: UInt64) -> Bool {
        guard self.sessionEpoch == sessionEpoch else { return false }
        self.sessionEpoch = nil
        observedChangeCount = nil
        delayIndex = 0
        return true
    }
}
