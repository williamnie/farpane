import Foundation

package enum ViewerClipboardTextPolicy {
    package static let maximumUTF8Bytes = 64 * 1024

    package static func accepts(_ text: String) -> Bool {
        !text.isEmpty
            && !text.contains("\0")
            && text.utf8.count <= maximumUTF8Bytes
    }
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
        guard self.sessionEpoch == sessionEpoch else {
            return ViewerClipboardPollDecision(
                textToSend: nil,
                nextDelayMilliseconds: nil
            )
        }

        if observedChangeCount == changeCount {
            delayIndex = min(
                delayIndex + 1,
                Self.productDelaysMilliseconds.count - 1
            )
            return ViewerClipboardPollDecision(
                textToSend: nil,
                nextDelayMilliseconds: Self.productDelaysMilliseconds[delayIndex]
            )
        }

        observedChangeCount = changeCount
        delayIndex = 0
        return ViewerClipboardPollDecision(
            textToSend: text().flatMap {
                ViewerClipboardTextPolicy.accepts($0) ? $0 : nil
            },
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
