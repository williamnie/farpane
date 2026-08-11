import Foundation

package protocol ViewerFileTransferSessionCore: AnyObject, Sendable {
    func requestFileTransferRecursiveManifest(
        sessionEpoch: UInt64,
        requestID: Int32
    ) -> Int32

    func startFileTransferDownload(
        _ request: ViewerFileTransferDownloadRequest,
        manifestRequestID: Int32,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onReceiveEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ) -> Int32

    func cancelFileTransfer(sessionEpoch: UInt64, transferID: Int32) -> Int32

    func discardFileTransferReceive(sessionEpoch: UInt64, transferID: Int32) -> Bool
}

package enum ViewerFileTransferSessionFailure: Equatable, Sendable {
    case manifest(ViewerFileTransferFailure)
    case receive(ViewerFileTransferReceiveFailure)
    case coreCommandRejected
    case protocolViolation
    case connectionClosed
}

package enum ViewerFileTransferSessionOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(ViewerFileTransferSessionFailure)
}

package enum ViewerFileTransferSessionEvent: Equatable, Sendable {
    case manifestRequested(sessionEpoch: UInt64, requestID: Int32, transferID: Int32)
    case progress(ViewerFileTransferProgressSnapshot)
    case fileCommitted(sessionEpoch: UInt64, transferID: Int32, fileNumber: Int)
    case finished(
        sessionEpoch: UInt64,
        transferID: Int32,
        outcome: ViewerFileTransferSessionOutcome
    )
}

package struct ViewerFileTransferSessionSnapshot: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let pendingManifestRequestID: Int32?
    package let pendingTransferID: Int32?
    package let activeTransferIDs: [Int32]
    package let isTornDown: Bool

    package init(
        sessionEpoch: UInt64,
        pendingManifestRequestID: Int32?,
        pendingTransferID: Int32?,
        activeTransferIDs: [Int32],
        isTornDown: Bool
    ) {
        self.sessionEpoch = sessionEpoch
        self.pendingManifestRequestID = pendingManifestRequestID
        self.pendingTransferID = pendingTransferID
        self.activeTransferIDs = activeTransferIDs
        self.isTornDown = isTornDown
    }
}

/// Owns every Viewer download resource for one exact Core connection epoch.
/// Recursive manifests are serialized because their empty-directory response
/// has no independent wire request ID; completed downloads may run concurrently.
package final class ViewerFileTransferSessionOwner: @unchecked Sendable {
    package static let maximumConcurrentDownloads =
        ViewerFileTransferProgressAuthority.maximumConcurrentTransfers

    private struct PendingDownload {
        let manifestRequestID: Int32
        let transferID: Int32
        let destinationOwner: ViewerFileTransferDestinationOwner
    }

    private enum TerminalProof: Equatable {
        case none
        case completed
        case cancelled
        case failed(CoreFileTransferFailure)
    }

    private struct ActiveDownload {
        let request: ViewerFileTransferDownloadRequest
        let destinationOwner: ViewerFileTransferDestinationOwner
        var nextCommittedFileNumber = 0
        var terminalProof: TerminalProof = .none
    }

    private let condition = NSCondition()
    private let sessionEpoch: UInt64
    private let core: any ViewerFileTransferSessionCore
    private let onEvent: @Sendable (ViewerFileTransferSessionEvent) -> Void
    private var manifestAuthority = ViewerFileTransferRecursiveManifestAuthority()
    private var progressAuthority = ViewerFileTransferProgressAuthority()
    private var pendingDownload: PendingDownload?
    private var activeDownloads: [Int32: ActiveDownload] = [:]
    private var operationsInFlight = 0
    private var teardownStarted = false
    private var teardownComplete = false

    package init?(
        sessionEpoch: UInt64,
        core: any ViewerFileTransferSessionCore,
        onEvent: @escaping @Sendable (ViewerFileTransferSessionEvent) -> Void
    ) {
        guard sessionEpoch > 0 else { return nil }
        self.sessionEpoch = sessionEpoch
        self.core = core
        self.onEvent = onEvent
    }

    deinit {
        _ = teardown(sessionEpoch: sessionEpoch)
    }

    package func snapshot() -> ViewerFileTransferSessionSnapshot {
        condition.lock()
        defer { condition.unlock() }
        return ViewerFileTransferSessionSnapshot(
            sessionEpoch: sessionEpoch,
            pendingManifestRequestID: pendingDownload?.manifestRequestID,
            pendingTransferID: pendingDownload?.transferID,
            activeTransferIDs: activeDownloads.keys.sorted(),
            isTornDown: teardownStarted
        )
    }

    /// On true, the session owner consumes destination lifetime authority. On
    /// false, no Core request was admitted and the caller retains that owner.
    @discardableResult
    package func beginDownload(
        manifestRequestID: Int32,
        transferID: Int32,
        destinationOwner: ViewerFileTransferDestinationOwner
    ) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            manifestRequestID > 0,
            transferID > 0,
            pendingDownload == nil,
            activeDownloads.count < Self.maximumConcurrentDownloads,
            activeDownloads[transferID] == nil,
            destinationOwner.lease?.sessionEpoch == sessionEpoch,
            manifestAuthority.begin(
                sessionEpoch: sessionEpoch,
                requestID: manifestRequestID
            )
        else {
            condition.unlock()
            return false
        }
        pendingDownload = PendingDownload(
            manifestRequestID: manifestRequestID,
            transferID: transferID,
            destinationOwner: destinationOwner
        )
        operationsInFlight += 1
        condition.unlock()

        let result = core.requestFileTransferRecursiveManifest(
            sessionEpoch: sessionEpoch,
            requestID: manifestRequestID
        )

        condition.lock()
        operationsInFlight -= 1
        condition.broadcast()
        if teardownStarted {
            condition.unlock()
            return true
        }
        guard result == 0 else {
            pendingDownload = nil
            _ = manifestAuthority.teardown(sessionEpoch: sessionEpoch)
            condition.unlock()
            return false
        }
        condition.unlock()
        onEvent(.manifestRequested(
            sessionEpoch: sessionEpoch,
            requestID: manifestRequestID,
            transferID: transferID
        ))
        return true
    }

    /// Returns true only when the event belongs to the current manifest
    /// request. A matching malformed response terminates that download.
    @discardableResult
    package func observeManifest(_ event: CoreFileTransferManifestEvent) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            let pending = pendingDownload,
            event.sessionEpoch == sessionEpoch,
            event.requestID == pending.manifestRequestID
        else {
            condition.unlock()
            return false
        }

        if event.status != .success {
            let failure: ViewerFileTransferFailure = event.status == .rejected
                ? .rejected
                : .unavailable
            guard case .failed(failure) = manifestAuthority.fail(
                sessionEpoch: sessionEpoch,
                requestID: pending.manifestRequestID,
                failure: failure
            ) else {
                return failPendingLocked(pending, failure: .protocolViolation)
            }
            pendingDownload = nil
            condition.unlock()
            closePending(pending, failure: .manifest(failure))
            return true
        }

        guard let part = event.recursiveManifestPart,
              let outcome = manifestAuthority.observe(
                sessionEpoch: sessionEpoch,
                requestID: pending.manifestRequestID,
                part: part
              )
        else {
            return failPendingLocked(pending, failure: .protocolViolation)
        }
        switch outcome {
        case .awaitingRemainingPart:
            condition.unlock()
            return true
        case .failed:
            return failPendingLocked(pending, failure: .protocolViolation)
        case .completed(let manifest):
            guard
                let lease = pending.destinationOwner.lease,
                let request = ViewerFileTransferDownloadRequest(
                    sessionEpoch: sessionEpoch,
                    transferID: pending.transferID,
                    destination: lease,
                    manifest: manifest
                ),
                let queued = progressAuthority.begin(request)
            else {
                return failPendingLocked(pending, failure: .protocolViolation)
            }
            pendingDownload = nil
            activeDownloads[pending.transferID] = ActiveDownload(
                request: request,
                destinationOwner: pending.destinationOwner
            )
            operationsInFlight += 1
            condition.unlock()

            let result = core.startFileTransferDownload(
                request,
                manifestRequestID: pending.manifestRequestID,
                destinationOwner: pending.destinationOwner
            ) { [weak self] receiveEvent in
                self?.observeReceive(
                    receiveEvent,
                    sessionEpoch: request.sessionEpoch,
                    transferID: request.transferID
                )
            }

            condition.lock()
            operationsInFlight -= 1
            condition.broadcast()
            guard !teardownStarted else {
                condition.unlock()
                return true
            }
            guard result == 0 else {
                let active = activeDownloads.removeValue(forKey: pending.transferID)
                _ = progressAuthority.teardown(
                    sessionEpoch: sessionEpoch,
                    transferID: pending.transferID
                )
                condition.unlock()
                if let active {
                    closeActive(active, outcome: .failed(.coreCommandRejected))
                }
                return true
            }
            let stillActive = activeDownloads[pending.transferID] != nil
            condition.unlock()
            if stillActive { onEvent(.progress(queued)) }
            return true
        }
    }

    /// Consumes only exact-session Core events for downloads owned here.
    @discardableResult
    package func observeCore(_ event: CoreFileTransferEvent) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            let active = activeDownloads[event.transferID],
            event.sessionEpoch == sessionEpoch
        else {
            condition.unlock()
            return false
        }
        guard
            event.totalFiles == UInt32(active.request.manifest.files.count),
            event.totalBytes == active.request.manifest.totalBytes,
            let update = event.viewerProgressUpdate
        else {
            return failActiveLocked(active, failure: .protocolViolation)
        }

        let terminalOutcome: ViewerFileTransferSessionOutcome?
        switch event.kind {
        case .progress, .waitingForConflict:
            terminalOutcome = nil
        case .completed:
            guard active.terminalProof == .completed else {
                return failActiveLocked(active, failure: .protocolViolation)
            }
            terminalOutcome = .completed
        case .cancelled:
            guard active.terminalProof == .cancelled else {
                return failActiveLocked(active, failure: .protocolViolation)
            }
            terminalOutcome = .cancelled
        case .failed:
            guard active.terminalProof == .failed(event.failure) else {
                return failActiveLocked(active, failure: .protocolViolation)
            }
            terminalOutcome = .failed(.receive(.remote(event.failure)))
        }

        guard let progress = progressAuthority.observe(update) else {
            return failActiveLocked(active, failure: .protocolViolation)
        }
        if terminalOutcome != nil {
            activeDownloads.removeValue(forKey: event.transferID)
        } else {
            activeDownloads[event.transferID] = active
        }
        condition.unlock()

        onEvent(.progress(progress))
        if let terminalOutcome {
            closeActive(active, outcome: terminalOutcome)
        }
        return true
    }

    @discardableResult
    package func requestCancellation(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            sessionEpoch == self.sessionEpoch,
            activeDownloads[transferID] != nil,
            let cancelling = progressAuthority.requestCancellation(
                sessionEpoch: sessionEpoch,
                transferID: transferID
            )
        else {
            condition.unlock()
            return false
        }
        operationsInFlight += 1
        condition.unlock()

        let result = core.cancelFileTransfer(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )

        condition.lock()
        operationsInFlight -= 1
        condition.broadcast()
        guard !teardownStarted else {
            condition.unlock()
            return false
        }
        if result == 0 {
            let stillActive = activeDownloads[transferID] != nil
            condition.unlock()
            if stillActive { onEvent(.progress(cancelling)) }
            return true
        }
        let active = activeDownloads.removeValue(forKey: transferID)
        _ = progressAuthority.teardown(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
        condition.unlock()
        if let active {
            _ = core.discardFileTransferReceive(
                sessionEpoch: sessionEpoch,
                transferID: transferID
            )
            closeActive(active, outcome: .failed(.coreCommandRejected))
        }
        return false
    }

    /// Exact connection teardown waits for synchronous Core operations, then
    /// cancels every admitted download before closing destination descriptors.
    @discardableResult
    package func teardown(sessionEpoch: UInt64) -> Bool {
        condition.lock()
        guard sessionEpoch == self.sessionEpoch, !teardownStarted else {
            if sessionEpoch == self.sessionEpoch {
                while teardownStarted && !teardownComplete { condition.wait() }
            }
            condition.unlock()
            return false
        }
        teardownStarted = true
        while operationsInFlight > 0 { condition.wait() }

        let pending = pendingDownload
        let active = activeDownloads.values.sorted {
            $0.request.transferID < $1.request.transferID
        }
        pendingDownload = nil
        activeDownloads.removeAll()
        _ = manifestAuthority.teardown(sessionEpoch: sessionEpoch)
        _ = progressAuthority.teardown(sessionEpoch: sessionEpoch)
        condition.unlock()

        var terminalEvents: [ViewerFileTransferSessionEvent] = []
        for item in active {
            _ = core.cancelFileTransfer(
                sessionEpoch: sessionEpoch,
                transferID: item.request.transferID
            )
            _ = core.discardFileTransferReceive(
                sessionEpoch: sessionEpoch,
                transferID: item.request.transferID
            )
            _ = item.destinationOwner.teardown(sessionEpoch: sessionEpoch)
            terminalEvents.append(.finished(
                sessionEpoch: sessionEpoch,
                transferID: item.request.transferID,
                outcome: .failed(.connectionClosed)
            ))
        }
        if let pending {
            _ = pending.destinationOwner.teardown(sessionEpoch: sessionEpoch)
            terminalEvents.append(.finished(
                sessionEpoch: sessionEpoch,
                transferID: pending.transferID,
                outcome: .failed(.connectionClosed)
            ))
        }

        condition.lock()
        teardownComplete = true
        condition.broadcast()
        condition.unlock()
        terminalEvents.forEach(onEvent)
        return true
    }

    private func observeReceive(
        _ event: ViewerFileTransferReceiveEvent,
        sessionEpoch: UInt64,
        transferID: Int32
    ) {
        condition.lock()
        guard
            !teardownStarted,
            sessionEpoch == self.sessionEpoch,
            var active = activeDownloads[transferID]
        else {
            condition.unlock()
            return
        }

        switch event {
        case .fileCommitted(let fileNumber):
            guard
                active.terminalProof == .none,
                fileNumber == active.nextCommittedFileNumber,
                active.request.manifest.files.indices.contains(fileNumber)
            else {
                _ = failActiveLocked(active, failure: .protocolViolation)
                return
            }
            active.nextCommittedFileNumber += 1
            activeDownloads[transferID] = active
            condition.unlock()
            onEvent(.fileCommitted(
                sessionEpoch: sessionEpoch,
                transferID: transferID,
                fileNumber: fileNumber
            ))
        case .completed:
            guard
                active.terminalProof == .none,
                active.nextCommittedFileNumber == active.request.manifest.files.count
            else {
                _ = failActiveLocked(active, failure: .protocolViolation)
                return
            }
            active.terminalProof = .completed
            activeDownloads[transferID] = active
            condition.unlock()
        case .cancelled:
            guard active.terminalProof == .none else {
                _ = failActiveLocked(active, failure: .protocolViolation)
                return
            }
            active.terminalProof = .cancelled
            activeDownloads[transferID] = active
            condition.unlock()
        case .failed(.remote(let failure)):
            guard active.terminalProof == .none, failure != .none else {
                _ = failActiveLocked(active, failure: .protocolViolation)
                return
            }
            active.terminalProof = .failed(failure)
            activeDownloads[transferID] = active
            condition.unlock()
        case .failed(let failure):
            activeDownloads.removeValue(forKey: transferID)
            _ = progressAuthority.teardown(
                sessionEpoch: sessionEpoch,
                transferID: transferID
            )
            condition.unlock()
            closeActive(active, outcome: .failed(.receive(failure)))
        }
    }

    private func failPendingLocked(
        _ pending: PendingDownload,
        failure: ViewerFileTransferSessionFailure
    ) -> Bool {
        pendingDownload = nil
        _ = manifestAuthority.teardown(sessionEpoch: sessionEpoch)
        condition.unlock()
        closePending(pending, failure: failure)
        return true
    }

    private func failActiveLocked(
        _ active: ActiveDownload,
        failure: ViewerFileTransferSessionFailure
    ) -> Bool {
        activeDownloads.removeValue(forKey: active.request.transferID)
        _ = progressAuthority.teardown(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID
        )
        condition.unlock()
        _ = core.cancelFileTransfer(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID
        )
        _ = core.discardFileTransferReceive(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID
        )
        closeActive(active, outcome: .failed(failure))
        return true
    }

    private func closePending(
        _ pending: PendingDownload,
        failure: ViewerFileTransferSessionFailure
    ) {
        _ = pending.destinationOwner.teardown(sessionEpoch: sessionEpoch)
        onEvent(.finished(
            sessionEpoch: sessionEpoch,
            transferID: pending.transferID,
            outcome: .failed(failure)
        ))
    }

    private func closeActive(
        _ active: ActiveDownload,
        outcome: ViewerFileTransferSessionOutcome
    ) {
        _ = active.destinationOwner.teardown(sessionEpoch: sessionEpoch)
        onEvent(.finished(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID,
            outcome: outcome
        ))
    }
}

extension RustDeskCoreClient: ViewerFileTransferSessionCore {}
