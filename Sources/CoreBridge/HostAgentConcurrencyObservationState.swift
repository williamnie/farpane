import Foundation

/// Sanitized Host runtime states accepted by the process-local coexistence
/// evidence ingress. These values never cross XPC or the Host ABI.
package enum HostAgentConcurrencyRuntimeState: Equatable, Sendable {
    case readyZeroInbound
    case inboundMediaActive
    case disconnected
}

package enum HostAgentConcurrencyRuntimeStatePolicy {
    package static func classify(
        hostState: String,
        registrationStatus: String,
        authenticatedConnectionCount: UInt64,
        hasActiveSession: Bool
    ) -> HostAgentConcurrencyRuntimeState? {
        if hostState == "ready", registrationStatus == "ready" {
            if authenticatedConnectionCount == 0, !hasActiveSession {
                return .readyZeroInbound
            }
            if authenticatedConnectionCount > 0, hasActiveSession {
                return .inboundMediaActive
            }
            return nil
        }
        switch hostState {
        case "created", "starting", "stopping", "stopped", "error":
            return .disconnected
        default:
            return nil
        }
    }
}

package struct HostAgentConcurrencyObservation: Equatable, Sendable {
    package let state: HostAgentConcurrencyRuntimeState
    package let hostInstanceID: String
    package let sourceGeneration: UInt64
}

package struct HostAgentConcurrencyObservationStateView: Equatable, Sendable {
    package let acceptedObservations: UInt64
    package let deliveredObservations: UInt64
    package let pendingObservations: Int
    package let lastSourceGeneration: UInt64
    package let bound: Bool
    package let failed: Bool
    package let cancelled: Bool
}

/// Bounded, process-boot-local bridge from accepted Core events and accepted
/// snapshot publications to one serialized evidence observer. Relevant events
/// may arrive before the runtime exposes its lease identity, so they are held
/// in memory and drained in exact source-generation order after binding.
package final class HostAgentConcurrencyObservationState:
    @unchecked Sendable
{
    package static let productCapacity = 256

    private let condition = NSCondition()
    private let capacity: Int
    private var observer:
        (@Sendable (HostAgentConcurrencyObservation) -> Void)?
    private var pending: [HostAgentConcurrencyObservation] = []
    private var delivering = false
    private var failed = false
    private var cancelled = false
    private var acceptedObservations: UInt64 = 0
    private var deliveredObservations: UInt64 = 0
    private var lastSourceGeneration: UInt64 = 0

    package init(capacity: Int = productCapacity) {
        self.capacity = max(1, min(capacity, Self.productCapacity))
        pending.reserveCapacity(self.capacity)
    }

    @discardableResult
    package func observe(event: HostCoreEvent) -> Bool {
        let state: HostAgentConcurrencyRuntimeState
        switch event.eventType {
        case "sessionStarted":
            state = .inboundMediaActive
        case "sessionEnded":
            state = .disconnected
        default:
            return false
        }
        return enqueue(state: state, hostInstanceID: event.hostInstanceId)
    }

    @discardableResult
    package func observe(snapshot: HostAgentSnapshotStateView) -> Bool {
        guard snapshot.status == .available,
              snapshot.refreshGeneration > 0,
              let projection = snapshot.projection,
              snapshot.hostInstanceID == projection.hostInstanceID,
              let state = Self.runtimeState(projection)
        else { return false }
        return enqueue(
            state: state,
            hostInstanceID: projection.hostInstanceID
        )
    }

    /// Installs the lease-bound evidence sink once. Delivery is synchronous
    /// for the one draining caller; concurrent producers only append bounded
    /// sanitized observations and cannot overtake an earlier generation.
    @discardableResult
    package func bind(
        observer: @escaping @Sendable (
            HostAgentConcurrencyObservation
        ) -> Void
    ) -> Bool {
        condition.lock()
        guard self.observer == nil, !failed, !cancelled else {
            condition.unlock()
            return false
        }
        self.observer = observer
        let shouldDrain = !pending.isEmpty && !delivering
        if shouldDrain { delivering = true }
        condition.unlock()
        if shouldDrain { drain() }
        return true
    }

    /// Rejects future ingress and waits for an in-flight evidence callback.
    package func cancelAndWait() {
        condition.lock()
        cancelled = true
        pending.removeAll(keepingCapacity: false)
        while delivering {
            condition.wait()
        }
        observer = nil
        condition.unlock()
    }

    package func snapshot() -> HostAgentConcurrencyObservationStateView {
        condition.lock()
        defer { condition.unlock() }
        return HostAgentConcurrencyObservationStateView(
            acceptedObservations: acceptedObservations,
            deliveredObservations: deliveredObservations,
            pendingObservations: pending.count,
            lastSourceGeneration: lastSourceGeneration,
            bound: observer != nil,
            failed: failed,
            cancelled: cancelled
        )
    }

    private func enqueue(
        state: HostAgentConcurrencyRuntimeState,
        hostInstanceID: String
    ) -> Bool {
        guard !hostInstanceID.isEmpty else { return false }
        condition.lock()
        guard !failed, !cancelled else {
            condition.unlock()
            return false
        }
        guard lastSourceGeneration < UInt64.max,
              pending.count < capacity
        else {
            failLocked()
            condition.unlock()
            return false
        }
        lastSourceGeneration += 1
        acceptedObservations += 1
        pending.append(HostAgentConcurrencyObservation(
            state: state,
            hostInstanceID: hostInstanceID,
            sourceGeneration: lastSourceGeneration
        ))
        let shouldDrain = observer != nil && !delivering
        if shouldDrain { delivering = true }
        condition.unlock()
        if shouldDrain { drain() }
        return true
    }

    private func drain() {
        while true {
            condition.lock()
            guard !failed, !cancelled, let observer,
                  !pending.isEmpty
            else {
                delivering = false
                condition.broadcast()
                condition.unlock()
                return
            }
            let observation = pending.removeFirst()
            condition.unlock()

            observer(observation)

            condition.lock()
            if deliveredObservations < UInt64.max {
                deliveredObservations += 1
            }
            condition.unlock()
        }
    }

    private func failLocked() {
        failed = true
        pending.removeAll(keepingCapacity: false)
    }

    private static func runtimeState(
        _ projection: HostAgentSnapshotProjection
    ) -> HostAgentConcurrencyRuntimeState? {
        HostAgentConcurrencyRuntimeStatePolicy.classify(
            hostState: projection.hostState,
            registrationStatus: projection.registrationStatus,
            authenticatedConnectionCount:
                projection.authenticatedConnectionCount,
            hasActiveSession: projection.activeSession != nil
        )
    }
}
