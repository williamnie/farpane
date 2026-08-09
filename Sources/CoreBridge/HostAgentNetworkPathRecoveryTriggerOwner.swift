import Foundation

package enum HostAgentNetworkPathAvailability: Equatable, Sendable {
    case satisfied
    case requiresConnection
    case unsatisfied
}

package enum HostAgentNetworkInterfaceKind: Hashable, Sendable {
    case other
    case wifi
    case cellular
    case wiredEthernet
    case loopback
}

package struct HostAgentNetworkPathSnapshot: Equatable, Sendable {
    package let availability: HostAgentNetworkPathAvailability
    package let interfaceKinds: Set<HostAgentNetworkInterfaceKind>
    package let supportsIPv4: Bool
    package let supportsIPv6: Bool
    package let supportsDNS: Bool
    package let isExpensive: Bool
    package let isConstrained: Bool

    package init(
        availability: HostAgentNetworkPathAvailability,
        interfaceKinds: Set<HostAgentNetworkInterfaceKind>,
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        supportsDNS: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.availability = availability
        self.interfaceKinds = interfaceKinds
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.supportsDNS = supportsDNS
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    fileprivate var isUsableForHostRecovery: Bool {
        availability == .satisfied
            && interfaceKinds.contains { $0 != .loopback }
            && (supportsIPv4 || supportsIPv6)
    }

    fileprivate var recoveryIdentity: HostAgentNetworkPathRecoveryIdentity {
        HostAgentNetworkPathRecoveryIdentity(
            interfaceKinds: interfaceKinds,
            supportsIPv4: supportsIPv4,
            supportsIPv6: supportsIPv6,
            supportsDNS: supportsDNS
        )
    }
}

private struct HostAgentNetworkPathRecoveryIdentity: Equatable {
    let interfaceKinds: Set<HostAgentNetworkInterfaceKind>
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool
}

package enum HostAgentNetworkPathRecoveryFailure: Equatable, Sendable {
    case invalidSatisfiedPath
    case generationExhausted
    case triggerRejected
}

package enum HostAgentNetworkPathRecoveryTriggerState:
    Equatable,
    Sendable
{
    case awaitingInitialPath(pathGeneration: UInt64)
    case observing(
        path: HostAgentNetworkPathSnapshot,
        pathGeneration: UInt64
    )
    case waitingForUsablePath(
        previousPath: HostAgentNetworkPathSnapshot?,
        pathGeneration: UInt64
    )
    case triggering(
        path: HostAgentNetworkPathSnapshot,
        pathGeneration: UInt64
    )
    case failed(
        pathGeneration: UInt64,
        reason: HostAgentNetworkPathRecoveryFailure
    )
    case cancelling
    case cancelled
}

package enum HostAgentNetworkPathRecoveryDisposition: Equatable, Sendable {
    case baselineEstablished
    case unavailableRecorded
    case unchanged
    case recoveryTriggered(pathGeneration: UInt64)
    case rejected
}

/// Normalizes path-monitor observations into exact, monotonic recovery edges.
/// Initial availability establishes a baseline without restarting HostCore.
/// A usable-path change or recovery from an observed outage triggers once;
/// duplicate, malformed, concurrent, failed, and post-cancel work fails closed.
package final class HostAgentNetworkPathRecoveryTriggerOwner:
    @unchecked Sendable
{
    package typealias Trigger = @Sendable (
        _ pathGeneration: UInt64,
        _ path: HostAgentNetworkPathSnapshot
    ) -> Bool

    private let condition = NSCondition()
    private let trigger: Trigger
    private var state: HostAgentNetworkPathRecoveryTriggerState
    private var operationInFlight = false

    package init(
        initialPathGeneration: UInt64 = 0,
        trigger: @escaping Trigger
    ) {
        self.trigger = trigger
        self.state = .awaitingInitialPath(
            pathGeneration: initialPathGeneration
        )
    }

    deinit {
        cancelAndWait()
    }

    package func stateSnapshot()
        -> HostAgentNetworkPathRecoveryTriggerState
    {
        condition.lock()
        defer { condition.unlock() }
        return state
    }

    @discardableResult
    package func consume(
        _ path: HostAgentNetworkPathSnapshot
    ) -> HostAgentNetworkPathRecoveryDisposition {
        condition.lock()
        guard !operationInFlight else {
            condition.unlock()
            return .rejected
        }

        switch state {
        case .awaitingInitialPath(let pathGeneration):
            let disposition = establishInitialPath(
                path,
                pathGeneration: pathGeneration
            )
            condition.unlock()
            return disposition

        case .observing(let currentPath, let pathGeneration):
            if path.availability == .satisfied,
               !path.isUsableForHostRecovery {
                state = .failed(
                    pathGeneration: pathGeneration,
                    reason: .invalidSatisfiedPath
                )
                condition.unlock()
                return .rejected
            }
            guard path.isUsableForHostRecovery else {
                state = .waitingForUsablePath(
                    previousPath: currentPath,
                    pathGeneration: pathGeneration
                )
                condition.unlock()
                return .unavailableRecorded
            }
            guard path.recoveryIdentity != currentPath.recoveryIdentity else {
                state = .observing(
                    path: path,
                    pathGeneration: pathGeneration
                )
                condition.unlock()
                return .unchanged
            }
            return triggerRecovery(
                path,
                previousGeneration: pathGeneration
            )

        case .waitingForUsablePath(_, let pathGeneration):
            if path.availability == .satisfied,
               !path.isUsableForHostRecovery {
                state = .failed(
                    pathGeneration: pathGeneration,
                    reason: .invalidSatisfiedPath
                )
                condition.unlock()
                return .rejected
            }
            guard path.isUsableForHostRecovery else {
                condition.unlock()
                return .unchanged
            }
            return triggerRecovery(
                path,
                previousGeneration: pathGeneration
            )

        case .triggering, .failed, .cancelling, .cancelled:
            condition.unlock()
            return .rejected
        }
    }

    /// Terminal and idempotent. Product teardown calls this outside the
    /// trigger closure so accepted recovery admission can drain first.
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
        case .awaitingInitialPath, .observing, .waitingForUsablePath,
             .triggering, .failed:
            state = .cancelling
            while operationInFlight {
                condition.wait()
            }
            state = .cancelled
            condition.broadcast()
            condition.unlock()
        }
    }

    private func establishInitialPath(
        _ path: HostAgentNetworkPathSnapshot,
        pathGeneration: UInt64
    ) -> HostAgentNetworkPathRecoveryDisposition {
        if path.availability == .satisfied {
            guard path.isUsableForHostRecovery else {
                state = .failed(
                    pathGeneration: pathGeneration,
                    reason: .invalidSatisfiedPath
                )
                return .rejected
            }
            state = .observing(
                path: path,
                pathGeneration: pathGeneration
            )
            return .baselineEstablished
        }
        state = .waitingForUsablePath(
            previousPath: nil,
            pathGeneration: pathGeneration
        )
        return .unavailableRecorded
    }

    private func triggerRecovery(
        _ path: HostAgentNetworkPathSnapshot,
        previousGeneration: UInt64
    ) -> HostAgentNetworkPathRecoveryDisposition {
        guard previousGeneration < UInt64.max else {
            state = .failed(
                pathGeneration: previousGeneration,
                reason: .generationExhausted
            )
            condition.unlock()
            return .rejected
        }
        let pathGeneration = previousGeneration + 1
        state = .triggering(
            path: path,
            pathGeneration: pathGeneration
        )
        operationInFlight = true
        condition.unlock()

        let accepted = trigger(pathGeneration, path)

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard state == .triggering(
            path: path,
            pathGeneration: pathGeneration
        ) else {
            condition.unlock()
            return .rejected
        }
        guard accepted else {
            state = .failed(
                pathGeneration: pathGeneration,
                reason: .triggerRejected
            )
            condition.unlock()
            return .rejected
        }
        state = .observing(
            path: path,
            pathGeneration: pathGeneration
        )
        condition.unlock()
        return .recoveryTriggered(pathGeneration: pathGeneration)
    }
}
