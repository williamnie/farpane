import Foundation

package enum HostAgentXPCCommandAdmissionConfigurationError:
    Error,
    Equatable
{
    case invalidCapacity
}

package enum HostAgentXPCCommandAdmissionRejection: Equatable, Sendable {
    case foreignIdentity
    case conflictingPayload
    case capacityExhausted
    case sequenceExhausted
    case invalidated
}

package enum HostAgentXPCCommandAdmissionState: Equatable, Sendable {
    case active
    case invalidated
}

package struct HostAgentXPCCommandReservation: Equatable, Sendable {
    fileprivate let sequence: UInt64
    fileprivate let commandID: String
    fileprivate let fingerprint: CommandFingerprint

    fileprivate init(
        sequence: UInt64,
        commandID: String,
        fingerprint: CommandFingerprint
    ) {
        self.sequence = sequence
        self.commandID = commandID
        self.fingerprint = fingerprint
    }
}

package enum HostAgentXPCCommandAdmissionResult: Equatable, Sendable {
    case reserved(HostAgentXPCCommandReservation)
    case pendingQueue
    case alreadyQueued
    case replay(HostAgentXPCWireCommandResult)
    case rejected(HostAgentXPCCommandAdmissionRejection)
}

package enum HostAgentXPCCommandResultRecordOutcome: Equatable, Sendable {
    case recorded
    case unchanged
    case unknownCommand
    case invalidated
}

package struct HostAgentXPCCommandAdmissionSnapshot: Equatable, Sendable {
    package let state: HostAgentXPCCommandAdmissionState
    package let retainedCount: Int
    package let reservedCount: Int
    package let queuedCount: Int
    package let completedCount: Int
    package let evictedCompletedCount: UInt64
    package let rejectedCount: UInt64
}

/// Boot-identity-bound, capacity-bounded command reservation and replay state.
/// It does not enqueue or execute work; only the future queue owner may turn an
/// exact reservation into `queued` before constructing an acknowledgement.
package final class HostAgentXPCCommandAdmissionAuthority:
    @unchecked Sendable
{
    package static let productCapacity = 256

    private static let allowedCapacity = 1...1_024

    private let lock = NSLock()
    private let identity: HostAgentXPCWireAgentIdentity
    private let capacity: Int
    private var state: HostAgentXPCCommandAdmissionState = .active
    private var nextReservationSequence: UInt64 = 0
    private var nextCompletionSequence: UInt64 = 0
    private var evictedCompletedCount: UInt64 = 0
    private var rejectedCount: UInt64 = 0
    private var entries: [String: CommandEntry] = [:]

    package init(
        identity: HostAgentXPCWireAgentIdentity,
        capacity: Int = HostAgentXPCCommandAdmissionAuthority.productCapacity
    ) throws {
        guard Self.allowedCapacity.contains(capacity) else {
            throw HostAgentXPCCommandAdmissionConfigurationError.invalidCapacity
        }
        self.identity = identity
        self.capacity = capacity
        entries.reserveCapacity(capacity)
    }

    package func reserve(
        _ request: HostAgentXPCWireCommandRequest
    ) -> HostAgentXPCCommandAdmissionResult {
        lock.lock()
        defer { lock.unlock() }

        guard state == .active else {
            incrementSaturating(&rejectedCount)
            return .rejected(.invalidated)
        }
        guard request.wireVersion
                == HostAgentXPCWireHandshakeContract.currentWireVersion,
              request.hostInstanceID == identity.hostInstanceID,
              request.agentBootID == identity.agentBootID
        else {
            incrementSaturating(&rejectedCount)
            return .rejected(.foreignIdentity)
        }
        let fingerprint = CommandFingerprint(request)
        if let existing = entries[request.commandID] {
            guard existing.fingerprint == fingerprint else {
                incrementSaturating(&rejectedCount)
                return .rejected(.conflictingPayload)
            }
            switch existing.phase {
            case .reserved:
                return .pendingQueue
            case .queued:
                return .alreadyQueued
            case .completed(let result, _):
                return .replay(result)
            }
        }
        guard makeRoomForNewEntryLocked() else {
            incrementSaturating(&rejectedCount)
            return .rejected(.capacityExhausted)
        }
        guard nextReservationSequence < UInt64.max else {
            transitionToInvalidatedLocked()
            incrementSaturating(&rejectedCount)
            return .rejected(.sequenceExhausted)
        }
        nextReservationSequence += 1
        let reservation = HostAgentXPCCommandReservation(
            sequence: nextReservationSequence,
            commandID: request.commandID,
            fingerprint: fingerprint
        )
        entries[request.commandID] = CommandEntry(
            fingerprint: fingerprint,
            phase: .reserved(sequence: reservation.sequence)
        )
        return .reserved(reservation)
    }

    /// Marks an exact live reservation queued. A false return must not produce
    /// a queued acknowledgement.
    @discardableResult
    package func markQueued(
        _ reservation: HostAgentXPCCommandReservation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active,
              let entry = entries[reservation.commandID],
              entry.fingerprint == reservation.fingerprint,
              case .reserved(let sequence) = entry.phase,
              sequence == reservation.sequence
        else { return false }
        entries[reservation.commandID] = CommandEntry(
            fingerprint: entry.fingerprint,
            phase: .queued
        )
        return true
    }

    /// Removes only the exact not-yet-queued reservation. Queued or completed
    /// work cannot be cancelled through this rollback seam.
    @discardableResult
    package func cancelReservation(
        _ reservation: HostAgentXPCCommandReservation
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active,
              let entry = entries[reservation.commandID],
              entry.fingerprint == reservation.fingerprint,
              case .reserved(let sequence) = entry.phase,
              sequence == reservation.sequence
        else { return false }
        entries.removeValue(forKey: reservation.commandID)
        return true
    }

    /// Records the final typed event result. Contradictory completion ordering
    /// or two different final results is a terminal internal-state failure.
    @discardableResult
    package func recordResult(
        _ result: HostAgentXPCWireCommandResult
    ) -> HostAgentXPCCommandResultRecordOutcome {
        lock.lock()
        defer { lock.unlock() }
        guard state == .active else { return .invalidated }
        guard let entry = entries[result.commandID] else {
            incrementSaturating(&rejectedCount)
            return .unknownCommand
        }
        switch entry.phase {
        case .reserved:
            transitionToInvalidatedLocked()
            return .invalidated
        case .queued:
            guard nextCompletionSequence < UInt64.max else {
                transitionToInvalidatedLocked()
                return .invalidated
            }
            nextCompletionSequence += 1
            entries[result.commandID] = CommandEntry(
                fingerprint: entry.fingerprint,
                phase: .completed(
                    result: result,
                    completionSequence: nextCompletionSequence
                )
            )
            return .recorded
        case .completed(let existing, _):
            guard existing == result else {
                transitionToInvalidatedLocked()
                return .invalidated
            }
            return .unchanged
        }
    }

    package func invalidate() {
        lock.lock()
        transitionToInvalidatedLocked()
        lock.unlock()
    }

    package func snapshot() -> HostAgentXPCCommandAdmissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var reservedCount = 0
        var queuedCount = 0
        var completedCount = 0
        for entry in entries.values {
            switch entry.phase {
            case .reserved: reservedCount += 1
            case .queued: queuedCount += 1
            case .completed: completedCount += 1
            }
        }
        return HostAgentXPCCommandAdmissionSnapshot(
            state: state,
            retainedCount: entries.count,
            reservedCount: reservedCount,
            queuedCount: queuedCount,
            completedCount: completedCount,
            evictedCompletedCount: evictedCompletedCount,
            rejectedCount: rejectedCount
        )
    }

    private func makeRoomForNewEntryLocked() -> Bool {
        guard entries.count >= capacity else { return true }
        let oldestCompleted = entries.min { left, right in
            completionSequence(left.value) < completionSequence(right.value)
        }
        guard let oldestCompleted,
              case .completed = oldestCompleted.value.phase
        else { return false }
        entries.removeValue(forKey: oldestCompleted.key)
        incrementSaturating(&evictedCompletedCount)
        return true
    }

    private func completionSequence(_ entry: CommandEntry) -> UInt64 {
        guard case .completed(_, let sequence) = entry.phase else {
            return UInt64.max
        }
        return sequence
    }

    private func transitionToInvalidatedLocked() {
        state = .invalidated
        entries.removeAll(keepingCapacity: false)
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}

private struct CommandFingerprint: Equatable, Sendable {
    let name: HostAgentXPCWireCommandName
    let connectionID: String

    init(_ request: HostAgentXPCWireCommandRequest) {
        name = request.name
        connectionID = request.connectionID
    }
}

private struct CommandEntry: Sendable {
    let fingerprint: CommandFingerprint
    let phase: CommandPhase
}

private enum CommandPhase: Sendable {
    case reserved(sequence: UInt64)
    case queued
    case completed(
        result: HostAgentXPCWireCommandResult,
        completionSequence: UInt64
    )
}
