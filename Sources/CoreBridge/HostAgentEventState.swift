import Foundation

package enum HostAgentEventStateConfigurationError: Error, Equatable {
    case invalidLimits
}

package enum HostAgentEventRejectionReason: Equatable, Sendable {
    case invalidEventID
    case oversizedEnvelope
    case foreignHostInstance
    case duplicateEventID
    case sequenceExhausted
}

package enum HostAgentEventIngestResult: Equatable, Sendable {
    case accepted(sequence: UInt64)
    case rejected(HostAgentEventRejectionReason)
}

package struct HostAgentEventRecord: Sendable {
    package let sequence: UInt64
    package let event: HostCoreEvent
}

package struct HostAgentEventStateSnapshot: Sendable {
    package let hostInstanceID: String?
    package let firstAvailableSequence: UInt64?
    package let latestSequence: UInt64
    package let evictedEventCount: UInt64
    package let rejectedEventCount: UInt64
    package let records: [HostAgentEventRecord]
}

/// Boot-lifetime, in-memory Host event journal. It assigns an arrival-order
/// sequence without assuming Rust event IDs are delivered in numeric order.
/// The fixed window bounds retained envelope data and makes eviction explicit.
package final class HostAgentEventState: @unchecked Sendable {
    package static let productCapacity = 256
    package static let productMaximumEventBytes = 16 * 1_024

    private static let allowedCapacity = 1...1_024
    private static let allowedMaximumEventBytes = 256...(64 * 1_024)

    private let lock = NSLock()
    private let capacity: Int
    private let maximumEventBytes: Int
    private var hostInstanceID: String?
    private var latestSequence: UInt64 = 0
    private var evictedEventCount: UInt64 = 0
    private var rejectedEventCount: UInt64 = 0
    private var records: [HostAgentEventRecord] = []
    private var retainedEventIDs: Set<UInt64> = []

    package init(
        capacity: Int = HostAgentEventState.productCapacity,
        maximumEventBytes: Int = HostAgentEventState.productMaximumEventBytes
    ) throws {
        guard Self.allowedCapacity.contains(capacity),
              Self.allowedMaximumEventBytes.contains(maximumEventBytes)
        else {
            throw HostAgentEventStateConfigurationError.invalidLimits
        }
        self.capacity = capacity
        self.maximumEventBytes = maximumEventBytes
        records.reserveCapacity(capacity)
    }

    @discardableResult
    package func ingest(_ event: HostCoreEvent) -> HostAgentEventIngestResult {
        lock.lock()
        defer { lock.unlock() }

        guard event.eventId > 0 else {
            return reject(.invalidEventID)
        }
        guard event.rawJSON.count <= maximumEventBytes else {
            return reject(.oversizedEnvelope)
        }
        if let hostInstanceID, hostInstanceID != event.hostInstanceId {
            return reject(.foreignHostInstance)
        }
        guard !retainedEventIDs.contains(event.eventId) else {
            return reject(.duplicateEventID)
        }
        guard latestSequence < UInt64.max else {
            return reject(.sequenceExhausted)
        }

        if hostInstanceID == nil {
            hostInstanceID = event.hostInstanceId
        }
        latestSequence += 1
        records.append(HostAgentEventRecord(
            sequence: latestSequence,
            event: event
        ))
        retainedEventIDs.insert(event.eventId)

        if records.count > capacity {
            let evicted = records.removeFirst()
            retainedEventIDs.remove(evicted.event.eventId)
            incrementSaturating(&evictedEventCount)
        }
        return .accepted(sequence: latestSequence)
    }

    /// Forwards only accepted events. Ingest releases the state lock before
    /// this callback runs, so downstream consumers may safely snapshot state.
    @discardableResult
    package func consume(
        _ event: HostCoreEvent,
        onAccepted: (HostCoreEvent) -> Void
    ) -> HostAgentEventIngestResult {
        let result = ingest(event)
        guard case .accepted = result else { return result }
        onAccepted(event)
        return result
    }

    package func snapshot() -> HostAgentEventStateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostAgentEventStateSnapshot(
            hostInstanceID: hostInstanceID,
            firstAvailableSequence: records.first?.sequence,
            latestSequence: latestSequence,
            evictedEventCount: evictedEventCount,
            rejectedEventCount: rejectedEventCount,
            records: records
        )
    }

    private func reject(
        _ reason: HostAgentEventRejectionReason
    ) -> HostAgentEventIngestResult {
        incrementSaturating(&rejectedEventCount)
        return .rejected(reason)
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }
}
