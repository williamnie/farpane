import Foundation

package protocol ViewerFileTransferUploadSessionCore: AnyObject, Sendable {
    func startFileTransferUpload(
        _ request: ViewerFileTransferUploadRequest,
        sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Int32

    func cancelFileTransfer(sessionEpoch: UInt64, transferID: Int32) -> Int32

    func discardFileTransferUpload(sessionEpoch: UInt64, transferID: Int32) -> Bool
}

/// Owns the upload request, progress authority and descriptor-backed source for
/// one exact file-only Core epoch. The source is never reopened by path.
package final class ViewerFileTransferUploadSessionOwner: @unchecked Sendable {
    private struct ActiveUpload {
        let request: ViewerFileTransferUploadRequest
        let sourceOwner: ViewerFileTransferUploadSourceOwner
    }

    private let condition = NSCondition()
    private let sessionEpoch: UInt64
    private let core: any ViewerFileTransferUploadSessionCore
    private let onEvent: @Sendable (ViewerFileTransferSessionEvent) -> Void
    private var progressAuthority = ViewerFileTransferProgressAuthority()
    private var activeUpload: ActiveUpload?
    private var operationInFlight = false
    private var teardownStarted = false
    private var teardownComplete = false

    package init?(
        sessionEpoch: UInt64,
        core: any ViewerFileTransferUploadSessionCore,
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

    package var activeTransferID: Int32? {
        condition.lock()
        defer { condition.unlock() }
        return activeUpload?.request.transferID
    }

    /// On success this owner consumes `sourceOwner` until a terminal callback
    /// or teardown. On failure the caller still owns it.
    @discardableResult
    package func beginUpload(
        transferID: Int32,
        sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            activeUpload == nil,
            let request = sourceOwner.makeUploadRequest(transferID: transferID),
            request.sessionEpoch == sessionEpoch,
            let queued = progressAuthority.begin(request)
        else {
            condition.unlock()
            return false
        }
        activeUpload = ActiveUpload(request: request, sourceOwner: sourceOwner)
        operationInFlight = true
        condition.unlock()

        let result = core.startFileTransferUpload(
            request,
            sourceOwner: sourceOwner
        )

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard !teardownStarted else {
            condition.unlock()
            return true
        }
        guard result == 0 else {
            let stillOwned = activeUpload?.request.transferID == transferID
            if stillOwned {
                activeUpload = nil
                _ = progressAuthority.teardown(
                    sessionEpoch: sessionEpoch,
                    transferID: transferID
                )
            }
            condition.unlock()
            return !stillOwned
        }
        let stillActive = activeUpload?.request.transferID == transferID
        condition.unlock()
        if stillActive { onEvent(.progress(queued)) }
        return true
    }

    @discardableResult
    package func observeCore(_ event: CoreFileTransferEvent) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            let active = activeUpload,
            event.sessionEpoch == sessionEpoch,
            event.transferID == active.request.transferID
        else {
            condition.unlock()
            return false
        }
        guard
            event.totalFiles == UInt32(active.request.manifest.files.count),
            event.totalBytes == active.request.manifest.totalBytes,
            let update = event.viewerProgressUpdate,
            let progress = progressAuthority.observe(update)
        else {
            return failActiveLocked(active, failure: .protocolViolation)
        }

        let outcome: ViewerFileTransferSessionOutcome?
        switch event.kind {
        case .progress, .waitingForConflict:
            outcome = nil
        case .completed:
            outcome = .completed
        case .cancelled:
            outcome = .cancelled
        case .failed:
            guard event.failure != .none else {
                return failActiveLocked(active, failure: .protocolViolation)
            }
            outcome = .failed(.receive(.remote(event.failure)))
        }
        if outcome != nil { activeUpload = nil }
        condition.unlock()

        onEvent(.progress(progress))
        if let outcome {
            _ = active.sourceOwner.teardown(sessionEpoch: sessionEpoch)
            onEvent(.finished(
                sessionEpoch: sessionEpoch,
                transferID: event.transferID,
                outcome: outcome
            ))
        }
        return true
    }

    @discardableResult
    package func requestCancellation(
        sessionEpoch: UInt64,
        transferID: Int32
    ) -> Bool {
        condition.lock()
        guard
            !teardownStarted,
            sessionEpoch == self.sessionEpoch,
            let active = activeUpload,
            active.request.transferID == transferID,
            let cancelling = progressAuthority.requestCancellation(
                sessionEpoch: sessionEpoch,
                transferID: transferID
            )
        else {
            condition.unlock()
            return false
        }
        operationInFlight = true
        condition.unlock()

        let result = core.cancelFileTransfer(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )

        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard !teardownStarted else {
            condition.unlock()
            return false
        }
        if result == 0 {
            let stillActive = activeUpload?.request.transferID == transferID
            condition.unlock()
            if stillActive { onEvent(.progress(cancelling)) }
            return true
        }
        guard activeUpload?.request.transferID == transferID else {
            condition.unlock()
            return false
        }
        activeUpload = nil
        _ = progressAuthority.teardown(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
        condition.unlock()
        _ = core.discardFileTransferUpload(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
        _ = active.sourceOwner.teardown(sessionEpoch: sessionEpoch)
        onEvent(.finished(
            sessionEpoch: sessionEpoch,
            transferID: transferID,
            outcome: .failed(.coreCommandRejected)
        ))
        return false
    }

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
        while operationInFlight { condition.wait() }
        let active = activeUpload
        activeUpload = nil
        _ = progressAuthority.teardown(sessionEpoch: sessionEpoch)
        condition.unlock()

        if let active {
            _ = core.cancelFileTransfer(
                sessionEpoch: sessionEpoch,
                transferID: active.request.transferID
            )
            _ = core.discardFileTransferUpload(
                sessionEpoch: sessionEpoch,
                transferID: active.request.transferID
            )
            _ = active.sourceOwner.teardown(sessionEpoch: sessionEpoch)
        }

        condition.lock()
        teardownComplete = true
        condition.broadcast()
        condition.unlock()
        return true
    }

    private func failActiveLocked(
        _ active: ActiveUpload,
        failure: ViewerFileTransferSessionFailure
    ) -> Bool {
        activeUpload = nil
        _ = progressAuthority.teardown(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID
        )
        condition.unlock()
        _ = core.cancelFileTransfer(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID
        )
        _ = core.discardFileTransferUpload(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID
        )
        _ = active.sourceOwner.teardown(sessionEpoch: sessionEpoch)
        onEvent(.finished(
            sessionEpoch: sessionEpoch,
            transferID: active.request.transferID,
            outcome: .failed(failure)
        ))
        return true
    }
}
