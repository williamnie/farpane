import Foundation

package enum HostAgentEventStateConfigurationError: Error, Equatable {
    case invalidLimits
}

package enum HostAgentEventRejectionReason: Equatable, Sendable {
    case invalidEventID
    case oversizedEnvelope
    case foreignHostInstance
    case duplicateEventID
    case typedCommandResultRequired
    case sequenceExhausted
}

package enum HostAgentEventIngestResult: Equatable, Sendable {
    case accepted(sequence: UInt64)
    case rejected(HostAgentEventRejectionReason)
}

package enum HostAgentEventRecordPayload: Sendable {
    case core(HostCoreEvent)
    case snapshotChanged(sentAtUnixMilliseconds: UInt64)
    case commandResult(
        HostAgentXPCWireCommandResult,
        sentAtUnixMilliseconds: UInt64
    )
}

package struct HostAgentEventRecord: Sendable {
    package let sequence: UInt64
    package let payload: HostAgentEventRecordPayload

    package init(sequence: UInt64, event: HostCoreEvent) {
        self.sequence = sequence
        payload = .core(event)
    }

    package init(
        sequence: UInt64,
        snapshotChangedAtUnixMilliseconds: UInt64
    ) {
        self.sequence = sequence
        payload = .snapshotChanged(
            sentAtUnixMilliseconds: snapshotChangedAtUnixMilliseconds
        )
    }

    package init(
        sequence: UInt64,
        commandResult: HostAgentXPCWireCommandResult,
        sentAtUnixMilliseconds: UInt64
    ) {
        self.sequence = sequence
        payload = .commandResult(
            commandResult,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        )
    }
}

package enum HostAgentCommandResultJournalRejectionReason:
    Equatable,
    Sendable
{
    case invalidHostInstance
    case invalidTimestamp
    case foreignHostInstance
    case conflictingCommandResult
    case sequenceExhausted
}

package enum HostAgentCommandResultJournalIngestResult:
    Equatable,
    Sendable
{
    case accepted(sequence: UInt64)
    case unchanged(sequence: UInt64)
    case rejected(HostAgentCommandResultJournalRejectionReason)
}

package enum HostAgentSnapshotChangeJournalRejectionReason:
    Equatable,
    Sendable
{
    case invalidHostInstance
    case invalidTimestamp
    case foreignHostInstance
    case sequenceExhausted
}

package enum HostAgentSnapshotChangeJournalIngestResult:
    Equatable,
    Sendable
{
    case accepted(sequence: UInt64)
    case rejected(HostAgentSnapshotChangeJournalRejectionReason)
}

package enum HostAgentEventReplayError: Error, Equatable {
    case invalidLimit
}

package enum HostAgentEventReplayResult: Sendable {
    case upToDate(latestSequence: UInt64)
    case batch(
        records: [HostAgentEventRecord],
        latestSequence: UInt64,
        hasMore: Bool
    )
    case gap(firstAvailableSequence: UInt64, latestSequence: UInt64)
    case invalidCursor(latestSequence: UInt64)
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
    package static let productReplayBatchSize = 64

    private static let allowedCapacity = 1...1_024
    private static let allowedMaximumEventBytes = 256...(64 * 1_024)
    private static let allowedReplayBatchSize = 1...productCapacity

    private let lock = NSLock()
    private let capacity: Int
    private let maximumEventBytes: Int
    private var hostInstanceID: String?
    private var latestSequence: UInt64 = 0
    private var evictedEventCount: UInt64 = 0
    private var rejectedEventCount: UInt64 = 0
    private var records: [HostAgentEventRecord] = []
    private var retainedEventIDs: Set<UInt64> = []
    private var retainedCommandResults: [String: RetainedCommandResult] = [:]

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
        guard event.eventType != "commandResult" else {
            return reject(.typedCommandResultRequired)
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
        evictIfNeededLocked()
        return .accepted(sequence: latestSequence)
    }

    /// Adds an already validated, typed command result to the same bounded
    /// local sequence as Core events. Equal retained results are idempotent;
    /// after eviction the admission authority may replay the result as a new
    /// local record without re-executing the command.
    @discardableResult
    package func ingestCommandResult(
        _ result: HostAgentXPCWireCommandResult,
        hostInstanceID candidateHostInstanceID: String,
        sentAtUnixMilliseconds: UInt64
    ) -> HostAgentCommandResultJournalIngestResult {
        lock.lock()
        defer { lock.unlock() }

        guard HostAgentXPCWireHandshakeContract.validIdentifier(
            candidateHostInstanceID
        ) else {
            return rejectCommandResult(.invalidHostInstance)
        }
        guard HostAgentXPCWireEventContract.validTimestamp(
            sentAtUnixMilliseconds
        ) else {
            return rejectCommandResult(.invalidTimestamp)
        }
        if let hostInstanceID,
           hostInstanceID != candidateHostInstanceID
        {
            return rejectCommandResult(.foreignHostInstance)
        }
        if let existing = retainedCommandResults[result.commandID] {
            guard existing.result == result else {
                return rejectCommandResult(.conflictingCommandResult)
            }
            return .unchanged(sequence: existing.sequence)
        }
        guard latestSequence < UInt64.max else {
            return rejectCommandResult(.sequenceExhausted)
        }

        if hostInstanceID == nil {
            hostInstanceID = candidateHostInstanceID
        }
        latestSequence += 1
        let sequence = latestSequence
        records.append(HostAgentEventRecord(
            sequence: sequence,
            commandResult: result,
            sentAtUnixMilliseconds: sentAtUnixMilliseconds
        ))
        retainedCommandResults[result.commandID] = RetainedCommandResult(
            sequence: sequence,
            result: result
        )
        evictIfNeededLocked()
        return .accepted(sequence: sequence)
    }

    /// 当 Core 轮询发现注册状态或会话可用性变化、但未发出 Core 事件时，
    /// 追加不含业务数据的快照刷新通知。
    @discardableResult
    package func ingestSnapshotChanged(
        hostInstanceID candidateHostInstanceID: String,
        sentAtUnixMilliseconds: UInt64
    ) -> HostAgentSnapshotChangeJournalIngestResult {
        lock.lock()
        defer { lock.unlock() }

        guard HostAgentXPCWireHandshakeContract.validIdentifier(
            candidateHostInstanceID
        ) else {
            return rejectSnapshotChange(.invalidHostInstance)
        }
        guard HostAgentXPCWireEventContract.validTimestamp(
            sentAtUnixMilliseconds
        ) else {
            return rejectSnapshotChange(.invalidTimestamp)
        }
        if let hostInstanceID,
           hostInstanceID != candidateHostInstanceID
        {
            return rejectSnapshotChange(.foreignHostInstance)
        }
        guard latestSequence < UInt64.max else {
            return rejectSnapshotChange(.sequenceExhausted)
        }

        if hostInstanceID == nil {
            hostInstanceID = candidateHostInstanceID
        }
        latestSequence += 1
        records.append(HostAgentEventRecord(
            sequence: latestSequence,
            snapshotChangedAtUnixMilliseconds: sentAtUnixMilliseconds
        ))
        evictIfNeededLocked()
        return .accepted(sequence: latestSequence)
    }

    /// Forwards only accepted events. Ingest releases the state lock before
    /// this callback runs, so downstream consumers may safely snapshot state.
    @discardableResult
    package func consume(
        _ event: HostCoreEvent,
        onAccepted: (HostCoreEvent, UInt64) -> Void
    ) -> HostAgentEventIngestResult {
        let result = ingest(event)
        guard case .accepted(let sequence) = result else { return result }
        onAccepted(event, sequence)
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

    /// Returns a single atomic journal view after the snapshot/event cursor.
    /// A gap means the caller must discard incremental state and fetch a new
    /// authoritative snapshot before attempting another replay.
    package func replay(
        afterSequence: UInt64,
        limit: Int = HostAgentEventState.productReplayBatchSize
    ) throws -> HostAgentEventReplayResult {
        guard Self.allowedReplayBatchSize.contains(limit) else {
            throw HostAgentEventReplayError.invalidLimit
        }

        lock.lock()
        defer { lock.unlock() }

        guard afterSequence <= latestSequence else {
            return .invalidCursor(latestSequence: latestSequence)
        }
        guard afterSequence < latestSequence else {
            return .upToDate(latestSequence: latestSequence)
        }
        guard let firstAvailableSequence = records.first?.sequence else {
            return .invalidCursor(latestSequence: latestSequence)
        }
        let nextSequence = afterSequence + 1
        guard nextSequence >= firstAvailableSequence else {
            return .gap(
                firstAvailableSequence: firstAvailableSequence,
                latestSequence: latestSequence
            )
        }

        let batch = Array(records.lazy
            .drop(while: { $0.sequence <= afterSequence })
            .prefix(limit))
        guard let lastSequence = batch.last?.sequence else {
            return .invalidCursor(latestSequence: latestSequence)
        }
        return .batch(
            records: batch,
            latestSequence: latestSequence,
            hasMore: lastSequence < latestSequence
        )
    }

    private func reject(
        _ reason: HostAgentEventRejectionReason
    ) -> HostAgentEventIngestResult {
        incrementSaturating(&rejectedEventCount)
        return .rejected(reason)
    }

    private func rejectCommandResult(
        _ reason: HostAgentCommandResultJournalRejectionReason
    ) -> HostAgentCommandResultJournalIngestResult {
        incrementSaturating(&rejectedEventCount)
        return .rejected(reason)
    }

    private func rejectSnapshotChange(
        _ reason: HostAgentSnapshotChangeJournalRejectionReason
    ) -> HostAgentSnapshotChangeJournalIngestResult {
        incrementSaturating(&rejectedEventCount)
        return .rejected(reason)
    }

    private func evictIfNeededLocked() {
        guard records.count > capacity else { return }
        let evicted = records.removeFirst()
        switch evicted.payload {
        case .core(let event):
            retainedEventIDs.remove(event.eventId)
        case .snapshotChanged:
            break
        case .commandResult(let result, _):
            if retainedCommandResults[result.commandID]?.sequence
                == evicted.sequence
            {
                retainedCommandResults.removeValue(forKey: result.commandID)
            }
        }
        incrementSaturating(&evictedEventCount)
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }
}

private struct RetainedCommandResult: Sendable {
    let sequence: UInt64
    let result: HostAgentXPCWireCommandResult
}
