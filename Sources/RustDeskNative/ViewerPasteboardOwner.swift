import AppKit
import CoreBridge
import Foundation

/// The only native Viewer owner allowed to touch NSPasteboard. Rust receives
/// and sends bounded text bytes only; this adapter binds those bytes to one
/// current App session and suppresses its own writes from the local poller.
final class ViewerPasteboardOwner {
    typealias SendText = (String) -> Int32

    private let pasteboard: NSPasteboard
    private var pollingState = ViewerClipboardPollingState()
    private var timer: Timer?
    private var sessionEpoch: UInt64?
    private var receiveEnabled = false
    private var sendEnabled = false
    private var active = false
    private var sendText: SendText?

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func begin(
        sessionEpoch: UInt64,
        receiveEnabled: Bool,
        sendEnabled: Bool,
        sendText: @escaping SendText
    ) -> Bool {
        guard
            Thread.isMainThread,
            sessionEpoch > 0,
            self.sessionEpoch == nil
        else { return false }
        self.sessionEpoch = sessionEpoch
        self.receiveEnabled = receiveEnabled
        self.sendEnabled = sendEnabled
        self.sendText = sendText
        return true
    }

    func activate(sessionEpoch: UInt64) {
        guard
            Thread.isMainThread,
            self.sessionEpoch == sessionEpoch,
            !active
        else { return }
        active = true
        guard sendEnabled else { return }
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
            receiveEnabled,
            ViewerClipboardTextPolicy.accepts(text)
        else { return }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return }

        guard sendEnabled, let delay = pollingState.observeOwnedWrite(
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
        if sendEnabled {
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
        receiveEnabled = false
        sendEnabled = false
        sendText = nil
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
            sendEnabled
        else { return }

        let changeCount = pasteboard.changeCount
        let decision = pollingState.observePoll(
            sessionEpoch: sessionEpoch,
            changeCount: changeCount,
            text: pasteboard.string(forType: .string)
        )
        if let text = decision.textToSend {
            _ = sendText?(text)
        }
        if let delay = decision.nextDelayMilliseconds {
            schedule(afterMilliseconds: delay, sessionEpoch: sessionEpoch)
        }
    }
}
