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
        label: String = "io.rustdesknative.exclusive-keyboard-send", send: @escaping Sender,
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

    public func enqueueKeyPress(
        _ key: CoreKey, sender: Sender? = nil, completion: @escaping @Sendable (Int32) -> Void
    ) {
        let send = sender ?? self.send
        queue.async { [send, recordResult] in
            let down = send(CoreKeyEvent(key: key, isDown: true))
            recordResult("key-down", down)
            // 即使按下失败也尝试释放；整对事件排在此前释放修饰键的事件之后。
            let up = send(CoreKeyEvent(key: key, isDown: false))
            recordResult("key-up", up)
            completion(down == 0 ? up : down)
        }
    }
}
