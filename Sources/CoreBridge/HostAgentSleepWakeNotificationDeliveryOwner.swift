import Foundation

package enum HostAgentSleepWakeNotificationEvent: Equatable, Sendable {
    case willSleep
    case didWake
}

package enum HostAgentSleepWakeNotificationDeliveryState:
    Equatable,
    Sendable
{
    case awake
    case preparingForSleep
    case sleeping
    case recoveringFromSleep
    case failed(HostAgentSleepWakeNotificationEvent)
    case cancelling
    case cancelled
}

/// Serializes the process-facing sleep/wake edge and rejects duplicates or
/// out-of-order notifications. Cancellation closes admission first and then
/// waits for the accepted delivery already in flight to finish.
package final class HostAgentSleepWakeNotificationDeliveryOwner:
    @unchecked Sendable
{
    private let condition = NSCondition()
    private let deliverWillSleep: @Sendable () -> Bool
    private let deliverDidWake: @Sendable () -> Bool
    private var state: HostAgentSleepWakeNotificationDeliveryState = .awake
    private var deliveryInFlight = false

    package init(
        deliverWillSleep: @escaping @Sendable () -> Bool,
        deliverDidWake: @escaping @Sendable () -> Bool
    ) {
        self.deliverWillSleep = deliverWillSleep
        self.deliverDidWake = deliverDidWake
    }

    deinit {
        cancelAndWait()
    }

    package func stateSnapshot()
        -> HostAgentSleepWakeNotificationDeliveryState
    {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    package func deliver(
        _ event: HostAgentSleepWakeNotificationEvent
    ) -> Bool {
        condition.lock()
        guard !deliveryInFlight,
              let transition = transitionForAcceptedEvent(event)
        else {
            condition.unlock()
            return false
        }
        state = transition
        deliveryInFlight = true
        condition.unlock()

        let accepted: Bool
        switch event {
        case .willSleep:
            accepted = deliverWillSleep()
        case .didWake:
            accepted = deliverDidWake()
        }

        condition.lock()
        deliveryInFlight = false
        if state != .cancelling {
            state = accepted ? completedState(for: event) : .failed(event)
        }
        condition.broadcast()
        condition.unlock()
        return accepted
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
        case .awake, .preparingForSleep, .sleeping,
             .recoveringFromSleep, .failed:
            state = .cancelling
            while deliveryInFlight {
                condition.wait()
            }
            state = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }

    private func transitionForAcceptedEvent(
        _ event: HostAgentSleepWakeNotificationEvent
    ) -> HostAgentSleepWakeNotificationDeliveryState? {
        switch (state, event) {
        case (.awake, .willSleep):
            return .preparingForSleep
        case (.sleeping, .didWake):
            return .recoveringFromSleep
        default:
            return nil
        }
    }

    private func completedState(
        for event: HostAgentSleepWakeNotificationEvent
    ) -> HostAgentSleepWakeNotificationDeliveryState {
        switch event {
        case .willSleep:
            return .sleeping
        case .didWake:
            return .awake
        }
    }
}
