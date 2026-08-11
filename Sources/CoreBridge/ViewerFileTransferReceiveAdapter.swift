import Foundation

package enum ViewerFileTransferReceiveFailure: Equatable, Sendable {
    case protocolViolation
    case localIO
    case durabilityUnconfirmed
    case connectionClosed
    case remote(CoreFileTransferFailure)
}

package enum ViewerFileTransferReceiveEvent: Equatable, Sendable {
    case fileCommitted(fileNumber: Int)
    case completed
    case cancelled
    case failed(ViewerFileTransferReceiveFailure)
}

package enum ViewerFileTransferReceiveBlockDisposition: Equatable, Sendable {
    case unhandled
    case accepted
    case cancelRequired
}

package enum ViewerFileTransferReceiveCoreEventDisposition: Equatable, Sendable {
    case unhandled
    case forward
    case suppress
    case cancelRequired
}

/// Serializes callback-owned blocks into one exact manifest and destination
/// lease. Paths and descriptors never leave the destination owner.
package final class ViewerFileTransferReceiveAdapter: @unchecked Sendable {
    package static let maximumConcurrentTransfers = 8

    private struct ActiveTransfer {
        let request: ViewerFileTransferDownloadRequest
        let destinationOwner: ViewerFileTransferDestinationOwner
        let onEvent: @Sendable (ViewerFileTransferReceiveEvent) -> Void
        var nextFileNumber = 0
        var reservation: ViewerFileTransferReceiveReservation?
        var bytesWritten: UInt64 = 0
    }

    private let stateLock = NSLock()
    private var activeTransfers: [Int32: ActiveTransfer] = [:]

    package init() {}

    package var activeCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeTransfers.count
    }

    package func begin(
        _ request: ViewerFileTransferDownloadRequest,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard
            activeTransfers.count < Self.maximumConcurrentTransfers,
            activeTransfers[request.transferID] == nil,
            destinationOwner.lease == request.destination
        else { return false }
        activeTransfers[request.transferID] = ActiveTransfer(
            request: request,
            destinationOwner: destinationOwner,
            onEvent: onEvent
        )
        return true
    }

    package func receive(
        _ block: CoreFileTransferReceiveBlock
    ) -> ViewerFileTransferReceiveBlockDisposition {
        stateLock.lock()
        guard var active = activeTransfers[block.transferID] else {
            stateLock.unlock()
            return .unhandled
        }
        let fileNumber = Int(block.fileNumber)
        guard
            block.sessionEpoch == active.request.sessionEpoch,
            fileNumber >= active.nextFileNumber,
            active.request.manifest.files.indices.contains(fileNumber)
        else {
            return failBlockLocked(
                active,
                failure: .protocolViolation
            )
        }

        var events: [ViewerFileTransferReceiveEvent] = []
        if let failure = materializeZeroFiles(
            active: &active,
            before: fileNumber,
            events: &events
        ) {
            return failBlockLocked(active, failure: failure, priorEvents: events)
        }
        guard
            active.nextFileNumber == fileNumber,
            active.request.manifest.files[fileNumber].size > 0
        else {
            return failBlockLocked(
                active,
                failure: .protocolViolation,
                priorEvents: events
            )
        }

        if active.reservation == nil {
            guard let reservation = active.destinationOwner.reserveNewFile(
                for: active.request,
                fileNumber: fileNumber
            ) else {
                return failBlockLocked(active, failure: .localIO, priorEvents: events)
            }
            active.reservation = reservation
            active.bytesWritten = 0
        }
        let payloadCount = UInt64(block.payload.count)
        let nextSize = active.bytesWritten.addingReportingOverflow(payloadCount)
        let declaredSize = active.request.manifest.files[fileNumber].size
        guard !nextSize.overflow, nextSize.partialValue <= declaredSize else {
            return failBlockLocked(
                active,
                failure: .protocolViolation,
                priorEvents: events
            )
        }
        guard
            let reservation = active.reservation,
            active.destinationOwner.writePayload(block.payload, to: reservation)
                == nextSize.partialValue
        else {
            return failBlockLocked(active, failure: .localIO, priorEvents: events)
        }
        active.bytesWritten = nextSize.partialValue

        if active.bytesWritten == declaredSize {
            let result = active.destinationOwner.commitReservation(reservation)
            active.reservation = nil
            active.bytesWritten = 0
            switch result {
            case .committed:
                events.append(.fileCommitted(fileNumber: fileNumber))
                active.nextFileNumber += 1
            case .rejected:
                return failBlockLocked(active, failure: .localIO, priorEvents: events)
            case .durabilityUnconfirmed:
                return failBlockLocked(
                    active,
                    failure: .durabilityUnconfirmed,
                    priorEvents: events
                )
            }
        }

        activeTransfers[block.transferID] = active
        stateLock.unlock()
        events.forEach(active.onEvent)
        return .accepted
    }

    package func observe(
        _ event: CoreFileTransferEvent
    ) -> ViewerFileTransferReceiveCoreEventDisposition {
        stateLock.lock()
        guard var active = activeTransfers[event.transferID] else {
            stateLock.unlock()
            return .unhandled
        }
        guard
            event.sessionEpoch == active.request.sessionEpoch,
            event.totalFiles == UInt32(active.request.manifest.files.count),
            event.totalBytes == active.request.manifest.totalBytes
        else {
            return failCoreEventLocked(
                active,
                failure: .protocolViolation,
                disposition: event.kind == .progress || event.kind == .waitingForConflict
                    ? .cancelRequired
                    : .suppress
            )
        }

        switch event.kind {
        case .progress, .waitingForConflict:
            let localBytes = locallyAcceptedBytes(active)
            guard
                Int(event.filesCompleted) <= active.nextFileNumber,
                event.bytesCompleted <= localBytes
            else {
                return failCoreEventLocked(
                    active,
                    failure: .protocolViolation,
                    disposition: .cancelRequired
                )
            }
            stateLock.unlock()
            return .forward
        case .cancelled:
            removeLocked(active)
            stateLock.unlock()
            active.onEvent(.cancelled)
            return .forward
        case .failed:
            guard event.failure != .none else {
                return failCoreEventLocked(active, failure: .protocolViolation)
            }
            removeLocked(active)
            stateLock.unlock()
            active.onEvent(.failed(.remote(event.failure)))
            return .forward
        case .completed:
            var events: [ViewerFileTransferReceiveEvent] = []
            guard active.reservation == nil else {
                return failCoreEventLocked(active, failure: .protocolViolation)
            }
            if let failure = materializeZeroFiles(
                active: &active,
                before: active.request.manifest.files.count,
                events: &events
            ) {
                return failCoreEventLocked(active, failure: failure, priorEvents: events)
            }
            guard active.nextFileNumber == active.request.manifest.files.count else {
                return failCoreEventLocked(
                    active,
                    failure: .protocolViolation,
                    priorEvents: events
                )
            }
            for directoryNumber in active.request.manifest.emptyDirectories.indices {
                switch active.destinationOwner.createEmptyDirectory(
                    for: active.request,
                    directoryNumber: directoryNumber
                ) {
                case .committed:
                    continue
                case .rejected:
                    return failCoreEventLocked(
                        active,
                        failure: .localIO,
                        priorEvents: events
                    )
                case .durabilityUnconfirmed:
                    return failCoreEventLocked(
                        active,
                        failure: .durabilityUnconfirmed,
                        priorEvents: events
                    )
                }
            }
            activeTransfers.removeValue(forKey: event.transferID)
            stateLock.unlock()
            events.forEach(active.onEvent)
            active.onEvent(.completed)
            return .forward
        }
    }

    /// Removes a route whose Core start failed. No terminal callback is
    /// emitted because the download was never admitted by Core.
    @discardableResult
    package func rollback(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        stateLock.lock()
        guard
            let active = activeTransfers[transferID],
            active.request.sessionEpoch == sessionEpoch
        else {
            stateLock.unlock()
            return false
        }
        removeLocked(active)
        stateLock.unlock()
        return true
    }

    @discardableResult
    package func teardown(sessionEpoch: UInt64) -> [Int32] {
        stateLock.lock()
        let removed = activeTransfers.values
            .filter { $0.request.sessionEpoch == sessionEpoch }
            .sorted { $0.request.transferID < $1.request.transferID }
        removed.forEach(removeLocked)
        stateLock.unlock()
        removed.forEach { $0.onEvent(.failed(.connectionClosed)) }
        return removed.map(\.request.transferID)
    }

    package func teardownAll() {
        stateLock.lock()
        let removed = Array(activeTransfers.values)
        removed.forEach(removeLocked)
        stateLock.unlock()
    }

    private func materializeZeroFiles(
        active: inout ActiveTransfer,
        before upperBound: Int,
        events: inout [ViewerFileTransferReceiveEvent]
    ) -> ViewerFileTransferReceiveFailure? {
        while active.nextFileNumber < upperBound {
            let fileNumber = active.nextFileNumber
            guard active.request.manifest.files[fileNumber].size == 0 else {
                return .protocolViolation
            }
            guard let reservation = active.destinationOwner.reserveNewFile(
                for: active.request,
                fileNumber: fileNumber
            ) else { return .localIO }
            switch active.destinationOwner.commitReservation(reservation) {
            case .committed:
                events.append(.fileCommitted(fileNumber: fileNumber))
                active.nextFileNumber += 1
            case .rejected:
                return .localIO
            case .durabilityUnconfirmed:
                return .durabilityUnconfirmed
            }
        }
        return nil
    }

    private func locallyAcceptedBytes(_ active: ActiveTransfer) -> UInt64 {
        let committed = active.request.manifest.files
            .prefix(active.nextFileNumber)
            .reduce(UInt64(0)) { $0 + $1.size }
        return committed + active.bytesWritten
    }

    private func failBlockLocked(
        _ active: ActiveTransfer,
        failure: ViewerFileTransferReceiveFailure,
        priorEvents: [ViewerFileTransferReceiveEvent] = []
    ) -> ViewerFileTransferReceiveBlockDisposition {
        removeLocked(active)
        stateLock.unlock()
        priorEvents.forEach(active.onEvent)
        active.onEvent(.failed(failure))
        return .cancelRequired
    }

    private func failCoreEventLocked(
        _ active: ActiveTransfer,
        failure: ViewerFileTransferReceiveFailure,
        priorEvents: [ViewerFileTransferReceiveEvent] = [],
        disposition: ViewerFileTransferReceiveCoreEventDisposition = .suppress
    ) -> ViewerFileTransferReceiveCoreEventDisposition {
        removeLocked(active)
        stateLock.unlock()
        priorEvents.forEach(active.onEvent)
        active.onEvent(.failed(failure))
        return disposition
    }

    private func removeLocked(_ active: ActiveTransfer) {
        activeTransfers.removeValue(forKey: active.request.transferID)
        if let reservation = active.reservation {
            _ = active.destinationOwner.cancelReservation(reservation)
        }
    }
}
