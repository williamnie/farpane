import Foundation

package enum HostAgentSnapshotStatus: Equatable, Sendable {
    case waiting
    case available
    case copyFailed
    case hostInstanceMismatch
    case staleSnapshot
}

package enum HostAgentSnapshotRejectionReason: Equatable, Sendable {
    case hostInstanceMismatch
    case staleEventSequence
    case staleObservedAt
}

package enum HostAgentSnapshotPublishResult: Equatable, Sendable {
    case published(generation: UInt64)
    case rejected(HostAgentSnapshotRejectionReason)
}

/// Sanitized reasons that terminally invalidate the process-lifetime XPC
/// handshake identity. Stale sequencing or observation time only degrades
/// snapshot availability and does not assert a contradictory process identity.
package enum HostAgentSnapshotIdentityInvalidationReason: Equatable, Sendable {
    case copyFailed
    case hostInstanceMismatch
}

/// Durable-in-memory projection for future snapshot-first IPC. The one-shot
/// revealed password and source raw JSON are intentionally not represented.
package struct HostAgentSnapshotProjection: Sendable {
    package let schemaVersion: Int
    package let hostInstanceID: String
    package let hostState: String
    package let localID: String
    package let registrationStatus: String
    package let recoveryEpoch: UInt64
    package let recoveryStatus: HostRecoveryStatus
    package let pendingApproval: HostPendingApproval?
    package let activeSession: HostActiveSession?
    package let temporaryPasswordPolicy: String
    package let passwordPolicy: HostPermanentPasswordPolicy
    package let lastError: String?
    package let observedAt: UInt64

    fileprivate init(snapshot: HostCoreSnapshot) {
        schemaVersion = snapshot.schemaVersion
        hostInstanceID = snapshot.hostInstanceId
        hostState = snapshot.hostState
        localID = snapshot.localId
        registrationStatus = snapshot.registrationStatus
        recoveryEpoch = snapshot.recoveryEpoch
        recoveryStatus = snapshot.recoveryStatus
        pendingApproval = snapshot.pendingApproval
        activeSession = snapshot.activeSession
        temporaryPasswordPolicy = "redacted"
        passwordPolicy = snapshot.passwordPolicy
        lastError = snapshot.lastError
        observedAt = snapshot.observedAt
    }
}

package struct HostAgentSnapshotStateView: Sendable {
    package let status: HostAgentSnapshotStatus
    package let refreshGeneration: UInt64
    package let eventSequence: UInt64
    package let hostInstanceID: String?
    package let lastAcceptedObservedAt: UInt64?
    package let failedRefreshCount: UInt64
    package let projection: HostAgentSnapshotProjection?
}

/// Atomic authority for the currently publishable Host snapshot projection.
/// Any copy or validation failure clears the current projection fail closed.
package final class HostAgentSnapshotState: @unchecked Sendable {
    private let lock = NSLock()
    private var status: HostAgentSnapshotStatus = .waiting
    private var refreshGeneration: UInt64 = 0
    private var eventSequence: UInt64 = 0
    private var hostInstanceID: String?
    private var lastAcceptedObservedAt: UInt64?
    private var failedRefreshCount: UInt64 = 0
    private var projection: HostAgentSnapshotProjection?

    @discardableResult
    package func publish(
        _ snapshot: HostCoreSnapshot,
        eventSequence: UInt64,
        expectedHostInstanceID: String?
    ) -> HostAgentSnapshotPublishResult {
        lock.lock()
        defer { lock.unlock() }
        incrementSaturating(&refreshGeneration)
        guard eventSequence >= self.eventSequence else {
            incrementSaturating(&failedRefreshCount)
            return .rejected(.staleEventSequence)
        }
        self.eventSequence = eventSequence

        guard expectedHostInstanceID == nil
                || expectedHostInstanceID == snapshot.hostInstanceId,
              hostInstanceID == nil || hostInstanceID == snapshot.hostInstanceId
        else {
            fail(.hostInstanceMismatch)
            return .rejected(.hostInstanceMismatch)
        }
        if let lastAcceptedObservedAt,
           snapshot.observedAt < lastAcceptedObservedAt
        {
            fail(.staleSnapshot)
            return .rejected(.staleObservedAt)
        }

        if hostInstanceID == nil {
            hostInstanceID = snapshot.hostInstanceId
        }
        lastAcceptedObservedAt = snapshot.observedAt
        projection = HostAgentSnapshotProjection(snapshot: snapshot)
        status = .available
        return .published(generation: refreshGeneration)
    }

    package func recordCopyFailure(eventSequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        incrementSaturating(&refreshGeneration)
        guard eventSequence >= self.eventSequence else {
            incrementSaturating(&failedRefreshCount)
            return
        }
        self.eventSequence = eventSequence
        fail(.copyFailed)
    }

    package func snapshot() -> HostAgentSnapshotStateView {
        lock.lock()
        defer { lock.unlock() }
        return HostAgentSnapshotStateView(
            status: status,
            refreshGeneration: refreshGeneration,
            eventSequence: eventSequence,
            hostInstanceID: hostInstanceID,
            lastAcceptedObservedAt: lastAcceptedObservedAt,
            failedRefreshCount: failedRefreshCount,
            projection: projection
        )
    }

    private func fail(_ status: HostAgentSnapshotStatus) {
        self.status = status
        projection = nil
        incrementSaturating(&failedRefreshCount)
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max {
            value += 1
        }
    }
}

/// Binds the snapshot copier after runtime startup. Event requests received
/// before binding are coalesced; one in-flight copy drains the latest pending
/// sequence before returning, so concurrent callbacks cannot lose a refresh.
package final class HostAgentSnapshotRefreshCoordinator: @unchecked Sendable {
    private struct RefreshRequest {
        let eventSequence: UInt64
        let hostInstanceID: String?
    }

    private let lock = NSCondition()
    private let state: HostAgentSnapshotState
    private var copySnapshot: (() throws -> HostCoreSnapshot)?
    private var onIdentityInvalidationRequired:
        ((HostAgentSnapshotIdentityInvalidationReason) -> Void)?
    private var identityInvalidationDelivered = false
    private var pending: RefreshRequest?
    private var pollPending = false
    private var refreshing = false
    private var cancelled = false
    private var lastCompletedSequence: UInt64?
    private var latestEventSequence: UInt64 = 0
    private var latestHostInstanceID: String?

    package init(state: HostAgentSnapshotState) {
        self.state = state
    }

    @discardableResult
    package func bind(
        copySnapshot: @escaping () throws -> HostCoreSnapshot,
        onIdentityInvalidationRequired: @escaping (
            HostAgentSnapshotIdentityInvalidationReason
        ) -> Void
    ) -> Bool {
        lock.lock()
        guard !cancelled,
              self.copySnapshot == nil,
              self.onIdentityInvalidationRequired == nil
        else {
            lock.unlock()
            return false
        }
        self.copySnapshot = copySnapshot
        self.onIdentityInvalidationRequired =
            onIdentityInvalidationRequired
        if pending == nil {
            pending = RefreshRequest(eventSequence: 0, hostInstanceID: nil)
        }
        guard !refreshing, let request = takePendingLocked() else {
            lock.unlock()
            return true
        }
        refreshing = true
        lock.unlock()
        drain(startingWith: request, copySnapshot: copySnapshot)
        return true
    }

    package func requestRefresh(
        eventSequence: UInt64,
        hostInstanceID: String
    ) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        if eventSequence >= latestEventSequence {
            latestEventSequence = eventSequence
            latestHostInstanceID = hostInstanceID
        }
        if let lastCompletedSequence, eventSequence <= lastCompletedSequence {
            lock.unlock()
            return
        }
        if let pending {
            if eventSequence >= pending.eventSequence {
                self.pending = RefreshRequest(
                    eventSequence: eventSequence,
                    hostInstanceID: hostInstanceID
                )
            }
        } else {
            pending = RefreshRequest(
                eventSequence: eventSequence,
                hostInstanceID: hostInstanceID
            )
        }
        guard let copySnapshot, !refreshing,
              let request = takePendingLocked()
        else {
            lock.unlock()
            return
        }
        refreshing = true
        lock.unlock()
        drain(startingWith: request, copySnapshot: copySnapshot)
    }

    /// Periodic registration refresh. Multiple ticks arriving during one copy
    /// coalesce into one additional copy at the current event sequence.
    package func requestPoll() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        guard let copySnapshot else {
            pollPending = true
            lock.unlock()
            return
        }
        guard !refreshing else {
            pollPending = true
            lock.unlock()
            return
        }
        let request = RefreshRequest(
            eventSequence: latestEventSequence,
            hostInstanceID: latestHostInstanceID
        )
        refreshing = true
        lock.unlock()
        drain(startingWith: request, copySnapshot: copySnapshot)
    }

    /// Stops accepting refreshes and waits for the current copy/drain loop.
    /// Must not be invoked by the active copy closure itself.
    package func cancelAndWait() {
        lock.lock()
        cancelled = true
        pending = nil
        pollPending = false
        while refreshing {
            lock.wait()
        }
        copySnapshot = nil
        onIdentityInvalidationRequired = nil
        lock.unlock()
    }

    private func drain(
        startingWith initialRequest: RefreshRequest,
        copySnapshot: @escaping () throws -> HostCoreSnapshot
    ) {
        var request = initialRequest
        while true {
            do {
                let snapshot = try copySnapshot()
                let result = state.publish(
                    snapshot,
                    eventSequence: request.eventSequence,
                    expectedHostInstanceID: request.hostInstanceID
                )
                if result == .rejected(.hostInstanceMismatch) {
                    requireIdentityInvalidation(.hostInstanceMismatch)
                }
            } catch {
                state.recordCopyFailure(eventSequence: request.eventSequence)
                requireIdentityInvalidation(.copyFailed)
            }

            lock.lock()
            if cancelled {
                pending = nil
                pollPending = false
                refreshing = false
                lock.broadcast()
                lock.unlock()
                return
            }
            if let lastCompletedSequence {
                if request.eventSequence > lastCompletedSequence {
                    self.lastCompletedSequence = request.eventSequence
                }
            } else {
                lastCompletedSequence = request.eventSequence
            }
            if let next = takePendingLocked(),
               next.eventSequence > (lastCompletedSequence ?? 0)
            {
                request = next
                lock.unlock()
                continue
            }
            if pollPending {
                pollPending = false
                request = RefreshRequest(
                    eventSequence: latestEventSequence,
                    hostInstanceID: latestHostInstanceID
                )
                lock.unlock()
                continue
            }
            pending = nil
            refreshing = false
            lock.broadcast()
            lock.unlock()
            return
        }
    }

    private func takePendingLocked() -> RefreshRequest? {
        let request = pending
        pending = nil
        return request
    }

    private func requireIdentityInvalidation(
        _ reason: HostAgentSnapshotIdentityInvalidationReason
    ) {
        lock.lock()
        guard !identityInvalidationDelivered,
              let onIdentityInvalidationRequired
        else {
            lock.unlock()
            return
        }
        identityInvalidationDelivered = true
        lock.unlock()
        onIdentityInvalidationRequired(reason)
    }
}
