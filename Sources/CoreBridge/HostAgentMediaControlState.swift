import Foundation

package struct HostAgentMediaRoute: Equatable, Sendable {
    package let connectionEpoch: UInt64
    package let codecEpoch: UInt64
    package let displayID: UInt64
    package let displayRevision: UInt64

    package init(
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        displayID: UInt64,
        displayRevision: UInt64
    ) {
        self.connectionEpoch = connectionEpoch
        self.codecEpoch = codecEpoch
        self.displayID = displayID
        self.displayRevision = displayRevision
    }
}

package enum HostAgentMediaControlRejectionReason: Equatable, Sendable {
    case invalidControl
    case cancelled
    case actionInFlight
    case staleEventSequence
    case missingRouteStart
    case staleRoute
    case routeMismatch
}

package enum HostAgentMediaControlDisposition: Equatable, Sendable {
    case ignored
    case accepted(command: HostMediaControl.Command, eventSequence: UInt64)
    case rejected(HostAgentMediaControlRejectionReason)
}

package struct HostAgentMediaControlStateSnapshot: Sendable {
    package let pendingRoute: HostAgentMediaRoute?
    package let activeRoute: HostAgentMediaRoute?
    package let latestAcceptedEventSequence: UInt64
    package let acceptedControlCount: UInt64
    package let rejectedControlCount: UInt64
    package let cancelled: Bool
}

/// Boot-lifetime single-route media-control authority. Rust remains the source
/// of route epochs; this state only admits the ordered controls that may reach
/// the process-local capture/encoder owner.
package final class HostAgentMediaControlState: @unchecked Sendable {
    private let condition = NSCondition()
    private var pendingRoute: HostAgentMediaRoute?
    private var activeRoute: HostAgentMediaRoute?
    private var highestConnectionEpoch: UInt64 = 0
    private var highestCodecEpoch: UInt64 = 0
    private var latestAcceptedEventSequence: UInt64 = 0
    private var acceptedControlCount: UInt64 = 0
    private var rejectedControlCount: UInt64 = 0
    private var actionInFlight = false
    private var cancelled = false

    package init() {}

    /// Non-media events are ignored. Accepted media actions run outside the
    /// condition lock; one action at a time preserves the serial Core event
    /// order and lets termination wait without racing Core teardown.
    @discardableResult
    package func consume(
        _ event: HostCoreEvent,
        eventSequence: UInt64,
        onAccepted: (HostMediaControl) -> Void
    ) -> HostAgentMediaControlDisposition {
        guard event.eventType == "mediaControl" else { return .ignored }
        condition.lock()
        guard !cancelled else {
            let result = rejectLocked(.cancelled)
            condition.unlock()
            return result
        }
        guard let control = event.mediaControl else {
            let result = rejectLocked(.invalidControl)
            condition.unlock()
            return result
        }
        guard !actionInFlight else {
            let result = rejectLocked(.actionInFlight)
            condition.unlock()
            return result
        }
        guard eventSequence > latestAcceptedEventSequence else {
            let result = rejectLocked(.staleEventSequence)
            condition.unlock()
            return result
        }
        if let reason = admissionRejectionLocked(for: control) {
            let result = rejectLocked(reason)
            condition.unlock()
            return result
        }

        latestAcceptedEventSequence = eventSequence
        incrementSaturating(&acceptedControlCount)
        actionInFlight = true
        condition.unlock()

        onAccepted(control)

        condition.lock()
        actionInFlight = false
        condition.broadcast()
        condition.unlock()
        return .accepted(
            command: control.command,
            eventSequence: eventSequence
        )
    }

    /// Terminal and idempotent. Must not be invoked by the active media action.
    package func cancelAndWait() {
        condition.lock()
        cancelled = true
        pendingRoute = nil
        activeRoute = nil
        while actionInFlight {
            condition.wait()
        }
        condition.unlock()
    }

    package func snapshot() -> HostAgentMediaControlStateSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return HostAgentMediaControlStateSnapshot(
            pendingRoute: pendingRoute,
            activeRoute: activeRoute,
            latestAcceptedEventSequence: latestAcceptedEventSequence,
            acceptedControlCount: acceptedControlCount,
            rejectedControlCount: rejectedControlCount,
            cancelled: cancelled
        )
    }

    private func admissionRejectionLocked(
        for control: HostMediaControl
    ) -> HostAgentMediaControlRejectionReason? {
        switch control.command {
        case .startCapture:
            guard let route = exactRoute(control) else { return .invalidControl }
            guard route.connectionEpoch > highestConnectionEpoch,
                  route.codecEpoch > highestCodecEpoch
            else { return .staleRoute }
            pendingRoute = route
            highestConnectionEpoch = route.connectionEpoch
            highestCodecEpoch = route.codecEpoch
            return nil

        case .reconfigure:
            guard let route = exactRoute(control) else { return .invalidControl }
            guard let pendingRoute else { return .missingRouteStart }
            guard pendingRoute == route else { return .routeMismatch }
            self.pendingRoute = nil
            activeRoute = route
            return nil

        case .requestIdr:
            guard let route = exactRoute(control) else { return .invalidControl }
            guard activeRoute == route else { return .routeMismatch }
            return nil

        case .stopCapture:
            var matched = false
            if let pendingRoute, matchesStop(control, route: pendingRoute) {
                self.pendingRoute = nil
                matched = true
            }
            if let activeRoute, matchesStop(control, route: activeRoute) {
                self.activeRoute = nil
                matched = true
            }
            return matched ? nil : .routeMismatch
        }
    }

    private func exactRoute(_ control: HostMediaControl) -> HostAgentMediaRoute? {
        guard control.connectionEpoch > 0,
              control.codecEpoch > 0,
              control.displayRevision > 0
        else { return nil }
        return HostAgentMediaRoute(
            connectionEpoch: control.connectionEpoch,
            codecEpoch: control.codecEpoch,
            displayID: control.displayID,
            displayRevision: control.displayRevision
        )
    }

    private func matchesStop(
        _ control: HostMediaControl,
        route: HostAgentMediaRoute
    ) -> Bool {
        control.connectionEpoch == route.connectionEpoch
            && control.codecEpoch == route.codecEpoch
            && control.displayID == route.displayID
            && (control.displayRevision == 0
                || control.displayRevision == route.displayRevision)
    }

    private func rejectLocked(
        _ reason: HostAgentMediaControlRejectionReason
    ) -> HostAgentMediaControlDisposition {
        incrementSaturating(&rejectedControlCount)
        return .rejected(reason)
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }
}
