import CoreBridge
import Foundation

/// Keeps potentially blocking Core input work away from the CGEventTap callback.
/// A private serial queue preserves the exact order in which the capture owner
/// admits key transitions.
public final class ExclusiveKeyboardEventDispatcher: @unchecked Sendable {
    public typealias Sender = @Sendable (CoreKeyEvent) -> Int32
    public typealias ResultRecorder = @Sendable (String, Int32) -> Void

    private let queue: DispatchQueue
    private let send: Sender
    private let recordResult: ResultRecorder

    public init(
        label: String = "io.rustdesknative.exclusive-keyboard-send",
        send: @escaping Sender,
        recordResult: @escaping ResultRecorder
    ) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        self.send = send
        self.recordResult = recordResult
    }

    public func enqueue(_ event: CoreKeyEvent) {
        queue.async { [send, recordResult] in
            let status = send(event)
            recordResult(event.isDown ? "key-down" : "key-up", status)
        }
    }
}
