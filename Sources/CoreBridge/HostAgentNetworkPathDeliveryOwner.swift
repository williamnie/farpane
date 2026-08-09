import Foundation

package enum HostAgentNetworkPathDeliveryDisposition: Equatable, Sendable {
    case accepted
    case rejected
    case closed
}

package enum HostAgentNetworkPathDeliveryState: Equatable, Sendable {
    case accepting
    case delivering
    case failed
    case cancelling
    case cancelled
}

/// Serializes normalized system path observations before they enter the
/// recovery trigger. Cancellation closes admission first and then drains the
/// one accepted delivery already in flight.
package final class HostAgentNetworkPathDeliveryOwner:
    @unchecked Sendable
{
    package typealias Deliver = @Sendable (
        _ path: HostAgentNetworkPathSnapshot
    ) -> Bool

    private let condition = NSCondition()
    private let deliverPath: Deliver
    private var state: HostAgentNetworkPathDeliveryState = .accepting
    private var deliveryInFlight = false

    package init(deliverPath: @escaping Deliver) {
        self.deliverPath = deliverPath
    }

    deinit {
        cancelAndWait()
    }

    package func stateSnapshot() -> HostAgentNetworkPathDeliveryState {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    package func deliver(
        _ path: HostAgentNetworkPathSnapshot
    ) -> HostAgentNetworkPathDeliveryDisposition {
        condition.lock()
        switch state {
        case .accepting where !deliveryInFlight:
            state = .delivering
            deliveryInFlight = true
            condition.unlock()
        case .accepting, .delivering, .failed:
            condition.unlock()
            return .rejected
        case .cancelling, .cancelled:
            condition.unlock()
            return .closed
        }

        let accepted = deliverPath(path)

        condition.lock()
        deliveryInFlight = false
        let cancelled = state == .cancelling
        if !cancelled {
            state = accepted ? .accepting : .failed
        }
        condition.broadcast()
        condition.unlock()
        if cancelled { return .closed }
        return accepted ? .accepted : .rejected
    }

    package func cancelAndWait() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while state == .cancelling {
                condition.wait()
            }
            condition.unlock()
            return
        case .accepting, .delivering, .failed:
            state = .cancelling
            while deliveryInFlight {
                condition.wait()
            }
            state = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }
}
