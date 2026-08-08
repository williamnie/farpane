import Foundation

package enum HostAgentMediaControlDeliveryStatus: Equatable, Sendable {
    case buffering
    case active
    case overflowed
    case cancelling
    case cancelled
}

package enum HostAgentMediaControlDeliveryDisposition: Equatable, Sendable {
    case buffered
    case queued
    case delivered
    case rejected
}

package struct HostAgentMediaControlDeliverySnapshot: Sendable {
    package let status: HostAgentMediaControlDeliveryStatus
    package let bufferedControlCount: Int
    package let deliveredControlCount: UInt64
    package let rejectedControlCount: UInt64
    package let deliveryInFlight: Bool
}

/// Bridges the bounded interval between HostCore event callback installation
/// and activation of the process-owned SCK/VideoToolbox pipeline owner.
/// Accepted startup controls are retained in order instead of being silently
/// dropped after the route authority has already advanced.
package final class HostAgentMediaControlDeliveryGate: @unchecked Sendable {
    package static let maximumBufferedControls = 16
    package typealias DeliveryHandler = @Sendable (HostMediaControl) -> Void

    private let condition = NSCondition()
    private var status: HostAgentMediaControlDeliveryStatus = .buffering
    private var pendingControls: [HostMediaControl] = []
    private var deliveredControlCount: UInt64 = 0
    private var rejectedControlCount: UInt64 = 0
    private var deliveryInFlight = false
    private var deliveryHandler: DeliveryHandler?

    package init() {}

    @discardableResult
    package func submit(_ control: HostMediaControl)
        -> HostAgentMediaControlDeliveryDisposition
    {
        condition.lock()
        switch status {
        case .buffering:
            guard appendLocked(control) else {
                condition.unlock()
                return .rejected
            }
            condition.unlock()
            return .buffered

        case .active:
            guard let deliveryHandler, appendLocked(control) else {
                condition.unlock()
                return .rejected
            }
            guard !deliveryInFlight else {
                condition.unlock()
                return .queued
            }
            deliveryInFlight = true
            let first = pendingControls.removeFirst()
            condition.unlock()
            drain(startingWith: first, deliver: deliveryHandler)
            return .delivered

        case .overflowed, .cancelling, .cancelled:
            incrementSaturating(&rejectedControlCount)
            condition.unlock()
            return .rejected
        }
    }

    /// Activates once and synchronously drains every startup control that was
    /// admitted before the pipeline owner became ready. False is terminal: an
    /// overflow or cancellation requires the HostAgent startup to fail closed.
    @discardableResult
    package func activate(
        deliver: @escaping DeliveryHandler
    ) -> Bool {
        condition.lock()
        guard status == .buffering else {
            condition.unlock()
            return false
        }
        status = .active
        deliveryHandler = deliver
        guard !pendingControls.isEmpty else {
            condition.unlock()
            return true
        }
        deliveryInFlight = true
        let first = pendingControls.removeFirst()
        condition.unlock()
        drain(startingWith: first, deliver: deliver)

        condition.lock()
        let activated = status == .active
        condition.unlock()
        return activated
    }

    /// Terminal and idempotent. Buffered controls are discarded and callers
    /// wait for the one synchronous delivery already outside the lock.
    package func cancelAndWait() {
        condition.lock()
        switch status {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while status == .cancelling {
                condition.wait()
            }
            condition.unlock()
            return
        case .buffering, .active, .overflowed:
            status = .cancelling
            pendingControls.removeAll(keepingCapacity: false)
            while deliveryInFlight {
                condition.wait()
            }
            deliveryHandler = nil
            status = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }

    package func snapshot() -> HostAgentMediaControlDeliverySnapshot {
        condition.lock()
        defer { condition.unlock() }
        return HostAgentMediaControlDeliverySnapshot(
            status: status,
            bufferedControlCount: pendingControls.count,
            deliveredControlCount: deliveredControlCount,
            rejectedControlCount: rejectedControlCount,
            deliveryInFlight: deliveryInFlight
        )
    }

    private func appendLocked(_ control: HostMediaControl) -> Bool {
        guard pendingControls.count < Self.maximumBufferedControls else {
            status = .overflowed
            pendingControls.removeAll(keepingCapacity: false)
            incrementSaturating(&rejectedControlCount)
            return false
        }
        pendingControls.append(control)
        return true
    }

    private func drain(
        startingWith first: HostMediaControl,
        deliver: DeliveryHandler
    ) {
        var control = first
        while true {
            deliver(control)
            condition.lock()
            incrementSaturating(&deliveredControlCount)
            guard status == .active, !pendingControls.isEmpty else {
                if status == .overflowed {
                    deliveryHandler = nil
                }
                deliveryInFlight = false
                condition.broadcast()
                condition.unlock()
                return
            }
            control = pendingControls.removeFirst()
            condition.unlock()
        }
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}
