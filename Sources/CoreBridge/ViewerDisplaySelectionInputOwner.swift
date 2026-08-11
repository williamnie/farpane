import Foundation

package enum ViewerDisplaySelectionInputResult: Equatable, Sendable {
    case admitted(CoreDisplaySelectionRequest)
    case catalogUnavailable
    case controlUnavailable
    case displayUnavailable
    case selectionPending
    case commandIDExhausted
    case coreRejected(Int32)
}

package enum ViewerDisplaySelectionInputFailure: Equatable, Sendable {
    case admissionRejected
    case terminal(CoreDisplaySelectionFailure)
}

package enum ViewerDisplaySelectionInputTerminalDecision: Equatable, Sendable {
    case ignored
    case awaitingCatalog
    case resumed
    case failed(CoreDisplaySelectionFailure)
}

package struct ViewerDisplaySelectionInputSnapshot: Equatable, Sendable {
    package let catalog: CoreDisplayCatalogEvent?
    package let pendingRequest: CoreDisplaySelectionRequest?
    package let failure: ViewerDisplaySelectionInputFailure?
    package let controlAvailable: Bool
    package let inputQuiesced: Bool
    package let stopped: Bool
}

/// Owns the Viewer-side input boundary around one display-selection command.
/// Core's return value is admission only. Held input stays released and new
/// input stays paused until an exact terminal success is also reflected by the
/// current revisioned catalog.
package final class ViewerDisplaySelectionInputOwner: @unchecked Sendable {
    package typealias SendSelection = @Sendable (CoreDisplaySelectionRequest) -> Int32
    package typealias InputAction = @Sendable () -> Void

    private let lock = NSLock()
    private let sendSelection: SendSelection
    private let quiesceInput: InputAction
    private let resumeInput: InputAction
    private var catalog: CoreDisplayCatalogEvent?
    private var pendingRequest: CoreDisplaySelectionRequest?
    private var pendingSuccess: CoreDisplaySelectionEvent?
    private var nextCommandID: UInt64 = 1
    private var failure: ViewerDisplaySelectionInputFailure?
    private var controlAvailable = false
    private var inputQuiesced = false
    private var stopped = false

    package init(
        initiallyQuiesced: Bool = false,
        sendSelection: @escaping SendSelection,
        quiesceInput: @escaping InputAction,
        resumeInput: @escaping InputAction
    ) {
        inputQuiesced = initiallyQuiesced
        self.sendSelection = sendSelection
        self.quiesceInput = quiesceInput
        self.resumeInput = resumeInput
    }

    package func snapshot() -> ViewerDisplaySelectionInputSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ViewerDisplaySelectionInputSnapshot(
            catalog: catalog,
            pendingRequest: pendingRequest,
            failure: failure,
            controlAvailable: controlAvailable,
            inputQuiesced: inputQuiesced,
            stopped: stopped
        )
    }

    package func setControlAvailable(_ available: Bool) {
        lock.lock()
        if !stopped { controlAvailable = available }
        lock.unlock()
    }

    @discardableResult
    package func observeCatalog(_ event: CoreDisplayCatalogEvent) -> Bool {
        var shouldResume = false
        lock.lock()
        guard !stopped, acceptsCatalogLocked(event) else {
            lock.unlock()
            return false
        }
        catalog = event
        if pendingSuccessMatchesCurrentCatalogLocked() {
            pendingRequest = nil
            pendingSuccess = nil
            inputQuiesced = false
            shouldResume = true
        }
        lock.unlock()
        if shouldResume { resumeInput() }
        return true
    }

    package func select(displayIndex: UInt32) -> ViewerDisplaySelectionInputResult {
        let request: CoreDisplaySelectionRequest
        let quiescedBeforeAttempt: Bool
        lock.lock()
        guard !stopped, let catalog, catalog.status == .available else {
            lock.unlock()
            return .catalogUnavailable
        }
        guard controlAvailable else {
            lock.unlock()
            return .controlUnavailable
        }
        guard pendingRequest == nil else {
            lock.unlock()
            return .selectionPending
        }
        guard catalog.entries.indices.contains(Int(displayIndex)),
              catalog.entries[Int(displayIndex)].online
        else {
            lock.unlock()
            return .displayUnavailable
        }
        guard nextCommandID > 0,
              let created = CoreDisplaySelectionRequest(
                  connectionEpoch: catalog.connectionEpoch,
                  commandID: nextCommandID,
                  catalogRevision: catalog.catalogRevision,
                  displayIndex: displayIndex
              )
        else {
            lock.unlock()
            return .commandIDExhausted
        }
        request = created
        nextCommandID = nextCommandID == UInt64.max ? 0 : nextCommandID + 1
        pendingRequest = request
        pendingSuccess = nil
        failure = nil
        quiescedBeforeAttempt = inputQuiesced
        inputQuiesced = true
        lock.unlock()

        if !quiescedBeforeAttempt { quiesceInput() }
        let status = sendSelection(request)
        guard status != 0 else { return .admitted(request) }

        var shouldResume = false
        lock.lock()
        if pendingRequest == request {
            pendingRequest = nil
            pendingSuccess = nil
            failure = .admissionRejected
            if !quiescedBeforeAttempt {
                inputQuiesced = false
                shouldResume = true
            }
        }
        lock.unlock()
        if shouldResume { resumeInput() }
        return .coreRejected(status)
    }

    package func observeSelection(
        _ event: CoreDisplaySelectionEvent
    ) -> ViewerDisplaySelectionInputTerminalDecision {
        var decision: ViewerDisplaySelectionInputTerminalDecision = .ignored
        var shouldResume = false
        lock.lock()
        guard !stopped, let request = pendingRequest,
              event.connectionEpoch == request.connectionEpoch,
              event.commandID == request.commandID,
              event.catalogRevision == request.catalogRevision,
              event.displayIndex == request.displayIndex
        else {
            lock.unlock()
            return .ignored
        }

        switch event.result {
        case .failed:
            pendingRequest = nil
            pendingSuccess = nil
            failure = .terminal(event.failure)
            decision = .failed(event.failure)
        case .selected, .alreadySelected:
            pendingSuccess = event
            if pendingSuccessMatchesCurrentCatalogLocked() {
                pendingRequest = nil
                pendingSuccess = nil
                failure = nil
                inputQuiesced = false
                shouldResume = true
                decision = .resumed
            } else {
                decision = .awaitingCatalog
            }
        }
        lock.unlock()
        if shouldResume { resumeInput() }
        return decision
    }

    /// Teardown deliberately never resumes input: the retiring connection is
    /// no longer an authority for local input delivery.
    package func stop() {
        lock.lock()
        stopped = true
        controlAvailable = false
        catalog = nil
        pendingRequest = nil
        pendingSuccess = nil
        failure = nil
        lock.unlock()
    }

    private func acceptsCatalogLocked(_ event: CoreDisplayCatalogEvent) -> Bool {
        guard let catalog else { return true }
        guard event.connectionEpoch >= catalog.connectionEpoch else { return false }
        if event.connectionEpoch == catalog.connectionEpoch {
            guard event.catalogRevision >= catalog.catalogRevision else { return false }
            if event.catalogRevision == catalog.catalogRevision {
                return event.status == catalog.status
                    && event.entries == catalog.entries
            }
        }
        return true
    }

    private func pendingSuccessMatchesCurrentCatalogLocked() -> Bool {
        guard let request = pendingRequest, let success = pendingSuccess,
              let catalog, catalog.status == .available
        else { return false }
        return success.connectionEpoch == request.connectionEpoch
            && success.commandID == request.commandID
            && success.catalogRevision == request.catalogRevision
            && success.displayIndex == request.displayIndex
            && catalog.connectionEpoch == request.connectionEpoch
            && catalog.catalogRevision == request.catalogRevision
            && catalog.selectedDisplayIndex == request.displayIndex
    }
}
