import Foundation

package protocol ViewerFileTransferProductCore:
    ViewerFileTransferSessionCore,
    AnyObject,
    Sendable
{
    func connect(_ config: CoreConnectionConfig) throws
    func disconnect()
}

package struct ViewerFileTransferProductCoreCallbacks: Sendable {
    package let onState: @Sendable (CoreStateEvent) -> Void
    package let onManifest: @Sendable (CoreFileTransferManifestEvent) -> Void
    package let onTransfer: @Sendable (CoreFileTransferEvent) -> Void

    package init(
        onState: @escaping @Sendable (CoreStateEvent) -> Void,
        onManifest: @escaping @Sendable (CoreFileTransferManifestEvent) -> Void,
        onTransfer: @escaping @Sendable (CoreFileTransferEvent) -> Void
    ) {
        self.onState = onState
        self.onManifest = onManifest
        self.onTransfer = onTransfer
    }
}

package enum ViewerFileTransferProductFailure: Equatable, Sendable {
    case coreUnavailable
    case authenticationRejected
    case connectionClosed
    case protocolViolation
}

package enum ViewerFileTransferProductPhase: Equatable, Sendable {
    case idle
    case connecting
    case ready
    case failed(ViewerFileTransferProductFailure)
    case tornDown
}

package enum ViewerFileTransferProductEvent: Equatable, Sendable {
    case connectionReady(sessionEpoch: UInt64)
    case connectionFailed(
        sessionEpoch: UInt64,
        failure: ViewerFileTransferProductFailure
    )
    case transfer(ViewerFileTransferSessionEvent)
}

package enum ViewerFileTransferProductDownloadRequestResult: Equatable, Sendable {
    case accepted(transferID: Int32)
    case destinationRejected
    case unavailable
}

package struct ViewerFileTransferProductSnapshot: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let phase: ViewerFileTransferProductPhase
    package let queuedTransferID: Int32?
    package let transfer: ViewerFileTransferSessionSnapshot?

    package init(
        sessionEpoch: UInt64,
        phase: ViewerFileTransferProductPhase,
        queuedTransferID: Int32?,
        transfer: ViewerFileTransferSessionSnapshot?
    ) {
        self.sessionEpoch = sessionEpoch
        self.phase = phase
        self.queuedTransferID = queuedTransferID
        self.transfer = transfer
    }
}

/// Owns one dedicated Viewer FILE_TRANSFER Core alongside, but never inside,
/// the desktop streaming Core. Construction is inert; only an explicit start
/// projects a file-only configuration and opens a network runtime.
package final class ViewerFileTransferProductComposition: @unchecked Sendable {
    package typealias CoreFactory = @Sendable (
        ViewerFileTransferProductCoreCallbacks
    ) throws -> any ViewerFileTransferProductCore

    private enum RoutedCoreEvent: Sendable {
        case state(CoreStateEvent)
        case manifest(CoreFileTransferManifestEvent)
        case transfer(CoreFileTransferEvent)
    }

    private struct QueuedDownload {
        let transferID: Int32
        let destinationOwner: ViewerFileTransferDestinationOwner
    }

    private let condition = NSCondition()
    private let sessionEpoch: UInt64
    private let makeCore: CoreFactory
    private let onEvent: @Sendable (ViewerFileTransferProductEvent) -> Void
    private var phase: ViewerFileTransferProductPhase = .idle
    private var core: (any ViewerFileTransferProductCore)?
    private var sessionOwner: ViewerFileTransferSessionOwner?
    private var queuedDownload: QueuedDownload?
    private var nextTransferID: Int32 = 0
    private var nextDestinationToken: UInt64 = 0
    private var operationInFlight = false
    private var pendingCoreEvents: [RoutedCoreEvent] = []
    private var teardownStarted = false
    private var teardownComplete = false

    package init?(
        sessionEpoch: UInt64,
        makeCore: @escaping CoreFactory,
        onEvent: @escaping @Sendable (ViewerFileTransferProductEvent) -> Void
    ) {
        guard sessionEpoch > 0 else { return nil }
        self.sessionEpoch = sessionEpoch
        self.makeCore = makeCore
        self.onEvent = onEvent
    }

    deinit {
        _ = teardown()
    }

    package func snapshot() -> ViewerFileTransferProductSnapshot {
        condition.lock()
        let phase = phase
        let owner = sessionOwner
        let queuedTransferID = queuedDownload?.transferID
        condition.unlock()
        return ViewerFileTransferProductSnapshot(
            sessionEpoch: sessionEpoch,
            phase: phase,
            queuedTransferID: queuedTransferID,
            transfer: owner?.snapshot()
        )
    }

    /// Starts a separate file-only Core. The base password is consumed only by
    /// this synchronous call and is not retained by the composition.
    @discardableResult
    package func start(baseConfiguration: CoreConnectionConfig) -> Bool {
        condition.lock()
        guard phase == .idle, !teardownStarted, !operationInFlight else {
            condition.unlock()
            return false
        }
        phase = .connecting
        operationInFlight = true
        condition.unlock()

        let callbacks = ViewerFileTransferProductCoreCallbacks(
            onState: { [weak self] event in self?.route(.state(event)) },
            onManifest: { [weak self] event in self?.route(.manifest(event)) },
            onTransfer: { [weak self] event in self?.route(.transfer(event)) }
        )

        do {
            let core = try makeCore(callbacks)
            guard let owner = ViewerFileTransferSessionOwner(
                sessionEpoch: sessionEpoch,
                core: core,
                onEvent: { [weak self] event in
                    self?.deliverSessionEvent(event)
                }
            ) else {
                core.disconnect()
                return finishStartFailure()
            }

            condition.lock()
            if teardownStarted {
                operationInFlight = false
                condition.broadcast()
                condition.unlock()
                _ = owner.teardown(sessionEpoch: sessionEpoch)
                core.disconnect()
                return false
            }
            self.core = core
            sessionOwner = owner
            condition.unlock()

            do {
                try core.connect(Self.dedicatedConfiguration(
                    from: baseConfiguration,
                    sessionEpoch: sessionEpoch
                ))
            } catch {
                return finishStartFailure()
            }

            condition.lock()
            operationInFlight = false
            condition.broadcast()
            let pending = pendingCoreEvents
            pendingCoreEvents.removeAll()
            condition.unlock()
            pending.forEach(consume)

            condition.lock()
            let accepted: Bool
            switch phase {
            case .connecting, .ready:
                accepted = !teardownStarted
            case .idle, .failed, .tornDown:
                accepted = false
            }
            condition.unlock()
            return accepted
        } catch {
            return finishStartFailure()
        }
    }

    /// Pins the user-selected destination immediately, starts the dedicated
    /// Core only for the first explicit action, and delays the manifest request
    /// until that file session is ready. No path or credential is retained.
    package func requestDownload(
        baseConfiguration: CoreConnectionConfig,
        destinationDirectory: URL
    ) -> ViewerFileTransferProductDownloadRequestResult {
        condition.lock()
        guard
            (phase == .idle || phase == .ready),
            !teardownStarted,
            !operationInFlight,
            queuedDownload == nil,
            nextTransferID < Int32.max,
            nextDestinationToken < UInt64.max
        else {
            condition.unlock()
            return .unavailable
        }
        nextTransferID += 1
        nextDestinationToken += 1
        let transferID = nextTransferID
        let token = nextDestinationToken
        let phaseAtAdmission = phase
        condition.unlock()

        guard let destination = ViewerFileTransferDestinationOwner(
            sessionEpoch: sessionEpoch,
            directoryURL: destinationDirectory,
            leaseToken: token
        ) else { return .destinationRejected }

        if phaseAtAdmission == .ready {
            guard beginDownload(
                transferID: transferID,
                destinationOwner: destination
            ) else {
                _ = destination.teardown(sessionEpoch: sessionEpoch)
                return .unavailable
            }
            return .accepted(transferID: transferID)
        }

        condition.lock()
        guard
            phase == .idle,
            !teardownStarted,
            !operationInFlight,
            queuedDownload == nil
        else {
            condition.unlock()
            _ = destination.teardown(sessionEpoch: sessionEpoch)
            return .unavailable
        }
        queuedDownload = QueuedDownload(
            transferID: transferID,
            destinationOwner: destination
        )
        condition.unlock()

        guard start(baseConfiguration: baseConfiguration) else {
            condition.lock()
            let queued = queuedDownload?.transferID == transferID
                ? queuedDownload
                : nil
            if queued != nil { queuedDownload = nil }
            condition.unlock()
            _ = queued?.destinationOwner.teardown(sessionEpoch: sessionEpoch)
            return .unavailable
        }
        return .accepted(transferID: transferID)
    }

    /// Creates a private descriptor owner only after the dedicated connection
    /// is ready. IDs and opaque lease tokens are monotonic and never reused.
    package func beginDownload(destinationDirectory: URL) -> Int32? {
        condition.lock()
        guard
            phase == .ready,
            !teardownStarted,
            let owner = sessionOwner,
            nextTransferID < Int32.max,
            nextDestinationToken < UInt64.max
        else {
            condition.unlock()
            return nil
        }
        nextTransferID += 1
        nextDestinationToken += 1
        let transferID = nextTransferID
        let token = nextDestinationToken
        condition.unlock()

        guard let destination = ViewerFileTransferDestinationOwner(
            sessionEpoch: sessionEpoch,
            directoryURL: destinationDirectory,
            leaseToken: token
        ) else { return nil }
        guard beginDownload(
            transferID: transferID,
            destinationOwner: destination,
            expectedOwner: owner
        ) else {
            _ = destination.teardown(sessionEpoch: sessionEpoch)
            return nil
        }
        return transferID
    }

    @discardableResult
    package func requestCancellation(transferID: Int32) -> Bool {
        condition.lock()
        if !teardownStarted,
           let queued = queuedDownload,
           queued.transferID == transferID {
            queuedDownload = nil
            condition.unlock()
            _ = queued.destinationOwner.teardown(sessionEpoch: sessionEpoch)
            deliverSessionEvent(.finished(
                sessionEpoch: sessionEpoch,
                transferID: transferID,
                outcome: .cancelled
            ))
            return true
        }
        guard phase == .ready, !teardownStarted, let owner = sessionOwner else {
            condition.unlock()
            return false
        }
        condition.unlock()
        return owner.requestCancellation(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
    }

    /// Closes the session authority and destination descriptors before the
    /// dedicated Core, so no callback can outlive its local write authority.
    @discardableResult
    package func teardown() -> Bool {
        condition.lock()
        guard !teardownStarted else {
            while !teardownComplete { condition.wait() }
            condition.unlock()
            return false
        }
        teardownStarted = true
        while operationInFlight { condition.wait() }
        let owner = sessionOwner
        let core = core
        let queued = queuedDownload
        sessionOwner = nil
        self.core = nil
        queuedDownload = nil
        pendingCoreEvents.removeAll()
        phase = .tornDown
        condition.unlock()

        _ = owner?.teardown(sessionEpoch: sessionEpoch)
        _ = queued?.destinationOwner.teardown(sessionEpoch: sessionEpoch)
        core?.disconnect()

        condition.lock()
        teardownComplete = true
        condition.broadcast()
        condition.unlock()
        return true
    }

    private func observeState(_ event: CoreStateEvent) {
        let failure: ViewerFileTransferProductFailure?
        condition.lock()
        guard !teardownStarted else {
            condition.unlock()
            return
        }
        switch event.state {
        case .streaming where phase == .connecting:
            phase = .ready
            condition.unlock()
            onEvent(.connectionReady(sessionEpoch: sessionEpoch))
            beginQueuedDownloadIfNeeded()
            return
        case .passwordRequired, .authenticationFailed:
            failure = .authenticationRejected
        case .disconnected:
            failure = .connectionClosed
        case .error, .controlReady:
            failure = .protocolViolation
        case .idle, .connecting, .transportReady, .authenticated,
             .streaming:
            failure = nil
        }
        guard let failure,
              phase == .connecting || phase == .ready
        else {
            condition.unlock()
            return
        }
        phase = .failed(failure)
        let owner = sessionOwner
        let queued = queuedDownload
        queuedDownload = nil
        condition.unlock()

        _ = owner?.teardown(sessionEpoch: sessionEpoch)
        _ = queued?.destinationOwner.teardown(sessionEpoch: sessionEpoch)
        onEvent(.connectionFailed(
            sessionEpoch: sessionEpoch,
            failure: failure
        ))
    }

    private func route(_ event: RoutedCoreEvent) {
        condition.lock()
        guard !teardownStarted else {
            condition.unlock()
            return
        }
        if operationInFlight {
            pendingCoreEvents.append(event)
            condition.unlock()
            return
        }
        condition.unlock()
        consume(event)
    }

    private func consume(_ event: RoutedCoreEvent) {
        switch event {
        case .state(let state):
            observeState(state)
        case .manifest(let manifest):
            observeManifest(manifest)
        case .transfer(let transfer):
            observeTransfer(transfer)
        }
    }

    private func observeManifest(_ event: CoreFileTransferManifestEvent) {
        condition.lock()
        let owner = phase == .ready && !teardownStarted ? sessionOwner : nil
        condition.unlock()
        _ = owner?.observeManifest(event)
    }

    private func observeTransfer(_ event: CoreFileTransferEvent) {
        condition.lock()
        let owner = phase == .ready && !teardownStarted ? sessionOwner : nil
        condition.unlock()
        _ = owner?.observeCore(event)
    }

    private func deliverSessionEvent(_ event: ViewerFileTransferSessionEvent) {
        condition.lock()
        let shouldDeliver = !teardownStarted
        condition.unlock()
        if shouldDeliver { onEvent(.transfer(event)) }
    }

    private func beginQueuedDownloadIfNeeded() {
        condition.lock()
        guard
            phase == .ready,
            !teardownStarted,
            let queued = queuedDownload
        else {
            condition.unlock()
            return
        }
        queuedDownload = nil
        condition.unlock()

        guard beginDownload(
            transferID: queued.transferID,
            destinationOwner: queued.destinationOwner
        ) else {
            _ = queued.destinationOwner.teardown(sessionEpoch: sessionEpoch)
            deliverSessionEvent(.finished(
                sessionEpoch: sessionEpoch,
                transferID: queued.transferID,
                outcome: .failed(.coreCommandRejected)
            ))
            return
        }
    }

    private func beginDownload(
        transferID: Int32,
        destinationOwner: ViewerFileTransferDestinationOwner,
        expectedOwner: ViewerFileTransferSessionOwner? = nil
    ) -> Bool {
        condition.lock()
        guard
            phase == .ready,
            !teardownStarted,
            let owner = sessionOwner,
            expectedOwner == nil || owner === expectedOwner
        else {
            condition.unlock()
            return false
        }
        condition.unlock()
        return owner.beginDownload(
            manifestRequestID: transferID,
            transferID: transferID,
            destinationOwner: destinationOwner
        )
    }

    private func finishStartFailure() -> Bool {
        condition.lock()
        operationInFlight = false
        condition.broadcast()
        guard !teardownStarted else {
            condition.unlock()
            return false
        }
        let owner = sessionOwner
        let core = core
        let queued = queuedDownload
        sessionOwner = nil
        self.core = nil
        queuedDownload = nil
        pendingCoreEvents.removeAll()
        phase = .failed(.coreUnavailable)
        condition.unlock()

        _ = owner?.teardown(sessionEpoch: sessionEpoch)
        _ = queued?.destinationOwner.teardown(sessionEpoch: sessionEpoch)
        core?.disconnect()
        onEvent(.connectionFailed(
            sessionEpoch: sessionEpoch,
            failure: .coreUnavailable
        ))
        return false
    }

    private static func dedicatedConfiguration(
        from base: CoreConnectionConfig,
        sessionEpoch: UInt64
    ) -> CoreConnectionConfig {
        CoreConnectionConfig(
            rendezvousServer: base.rendezvousServer,
            serverPublicKey: base.serverPublicKey,
            peerID: base.peerID,
            password: base.password,
            forceRelay: base.forceRelay,
            receiveClipboardText: false,
            sendClipboardText: false,
            receiveClipboardRichText: false,
            sendClipboardRichText: false,
            receiveClipboardImage: false,
            sendClipboardImage: false,
            fileTransferEnabled: true,
            fileTransferSessionEpoch: sessionEpoch
        )
    }
}

extension RustDeskCoreClient: ViewerFileTransferProductCore {}
