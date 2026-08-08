import Foundation

/// Latches one process termination request even when it arrives before the
/// runtime lifetime has bound its delivery handler.
public final class HostAgentTerminationRequestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var bound = false
    private var handler: (() -> Void)?

    public init() {}

    /// Binds exactly one delivery handler. A previously latched request is
    /// delivered synchronously after releasing the lock.
    @discardableResult
    public func bind(handler: @escaping () -> Void) -> Bool {
        let delivery: (() -> Void)?
        lock.lock()
        guard !bound else {
            lock.unlock()
            return false
        }
        bound = true
        if requested {
            delivery = handler
        } else {
            self.handler = handler
            delivery = nil
        }
        lock.unlock()

        delivery?()
        return true
    }

    /// Records the first request only. If already bound, delivery occurs
    /// synchronously after releasing the lock; duplicates return false.
    @discardableResult
    public func requestTermination() -> Bool {
        let delivery: (() -> Void)?
        lock.lock()
        guard !requested else {
            lock.unlock()
            return false
        }
        requested = true
        delivery = handler
        handler = nil
        lock.unlock()

        delivery?()
        return true
    }
}
