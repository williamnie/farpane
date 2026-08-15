import CoreBridge
import CoreGraphics
import Foundation
import VideoPipeline

enum HostAgentMediaPipelineLifecycleStatus: String, Sendable {
    case idle
    case active
    case cancelling
    case cancelled
}

enum HostAgentMediaCapabilityStatus: String, Sendable {
    case notStarted
    case probing
    case ready
    case failed
    case cancelled
}

struct HostAgentMediaPipelineSnapshot: Sendable {
    let lifecycleStatus: HostAgentMediaPipelineLifecycleStatus
    let capabilityStatus: HostAgentMediaCapabilityStatus
    let capabilityFailures: UInt64
    let pipelineStartFailures: UInt64
    let pipelineRuntimeFailures: UInt64
    let rejectedControls: UInt64
    let acceptedMediaDiagnostics: UInt64
    let acceptedTelemetryUpdates: UInt64
    let rejectedDiagnostics: UInt64
    let lastMediaDiagnosticKind: HostMediaDiagnostic.Kind?
    let lastMediaDiagnosticRoute: HostMediaPipelineRouteIdentity?
    let controlIngress: HostAgentMediaControlDeliverySnapshot
    let recovery: HostMediaPipelineRecoverySnapshot
    let recoveryPolling: HostMediaPipelineRecoveryPollingState
    let displayRecoveryEvidence: HostDisplayReconfigureEvidenceState
    let routeOwner: HostMediaPipelineRouteOwnerSnapshot
    let liveLog: HostMediaPipelineLiveLogCoordinatorSnapshot
}

/// Process-owned adapter from typed Rust media controls to the real
/// ScreenCaptureKit/VideoToolbox pipeline. It never touches AppDelegate/UI.
final class HostAgentMediaPipelineOwner: @unchecked Sendable {
    typealias MediaRecoveryCompletion = @Sendable (
        _ epoch: UInt64,
        _ succeeded: Bool
    ) -> Void

    private enum State {
        case idle
        case active
        case cancelling
        case cancelled
    }

    private let condition = NSCondition()
    private let runtimeBinding: HostAgentMediaRuntimeBinding
    private let status: HostAgentMediaPipelineStatus
    private let controlDeliveryGate: HostAgentMediaControlDeliveryGate
    private let liveLogCoordinator: HostMediaPipelineLiveLogCoordinator
    private let liveLogPollingOwner: HostAgentMediaLiveLogPollingOwner
    private let routeOwner: HostMediaPipelineRouteOwner
    private let recoveryOwner: HostMediaPipelineRecoveryOwner
    private let recoveryPollingOwner: HostMediaPipelineRecoveryPollingOwner
    private let displayEvidenceOwner: HostDisplayReconfigureEvidenceOwner
    private var state: State = .idle
    private var capabilityTask: Task<Void, Never>?
    private var capabilityInFlight = false
    private var capabilityRefreshPending = false
    private var diagnosticsInFlight = 0

    init(
        recoveryEvidenceOwner: HostRecoveryTransitionEvidenceProcessOwner
    ) {
        let runtimeBinding = HostAgentMediaRuntimeBinding()
        let status = HostAgentMediaPipelineStatus()
        let liveLogCoordinator = HostMediaPipelineLiveLogCoordinator()
        self.runtimeBinding = runtimeBinding
        self.status = status
        self.controlDeliveryGate = HostAgentMediaControlDeliveryGate()
        self.liveLogCoordinator = liveLogCoordinator
        self.liveLogPollingOwner = HostAgentMediaLiveLogPollingOwner(
            coordinator: liveLogCoordinator
        )
        let routeOwner = HostMediaPipelineRouteOwner(
            lifecycleObserver: liveLogCoordinator.lifecycleObserver,
            onSubmit: { route, unit in
                runtimeBinding.submit(route: route, unit: unit)
            },
            onEncoderState: { route, encoderState in
                runtimeBinding.reportEncoderState(
                    route: route,
                    state: encoderState
                )
            },
            onFailure: { _, failure in
                status.record(failure: failure)
            }
        )
        self.routeOwner = routeOwner
        self.recoveryOwner = HostMediaPipelineRecoveryOwner(
            routeOwner: routeOwner
        )
        self.recoveryPollingOwner =
            HostMediaPipelineRecoveryPollingOwner.makeProduct(
                poll: { [recoveryOwner] in
                    recoveryOwner.pollRecoveryConvergence()
                }
            )
        self.displayEvidenceOwner = HostDisplayReconfigureEvidenceOwner(
            evidenceOwner: recoveryEvidenceOwner,
            routePoll: { [routeOwner] route in
                let snapshot = routeOwner.snapshot()
                guard snapshot.pendingOperationCount == 0 else {
                    return .pending
                }
                guard snapshot.desiredRoute == route,
                      snapshot.activeRoute == route
                else { return .failed }
                return .converged
            }
        )
    }

    deinit {
        cancelAndWait()
    }

    /// Binds only weak runtime access, then probes the exact active-display
    /// envelope before advertising codecs to Rust. Probe failure stays
    /// fail-closed: Rust will not create a native media route.
    @discardableResult
    func start(
        lifetime: HostAgentProcessLifetime,
        hostInstanceID: String
    ) -> Bool {
        guard !hostInstanceID.isEmpty,
              runtimeBinding.bind(
                lifetime: lifetime,
                hostInstanceID: hostInstanceID
              )
        else { return false }

        condition.lock()
        guard case .idle = state else {
            condition.unlock()
            runtimeBinding.cancel()
            return false
        }
        state = .active
        condition.unlock()

        guard controlDeliveryGate.activate(deliver: { [weak self] control in
            self?.deliver(control)
        }) else {
            cancelAndWait()
            return false
        }

        condition.lock()
        guard case .active = state else {
            condition.unlock()
            return false
        }
        capabilityInFlight = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCapabilityWork()
        }
        capabilityTask = task
        condition.unlock()
        _ = liveLogPollingOwner.start()
        return true
    }

    func handle(_ control: HostMediaControl) {
        let disposition = controlDeliveryGate.submit(control)
        if disposition == .rejected {
            status.recordControlRejection()
        }
    }

    private func deliver(_ control: HostMediaControl) {
        switch control.command {
        case .startCapture:
            // H4.1u has already recorded the pending route. Rust follows this
            // with the exact reconfigure that contains the encoder contract.
            guard recoveryOwner.acceptStartCapture() else {
                _ = displayEvidenceOwner.observeStart(
                    Self.displayEvidenceStart(from: control)
                )
                status.recordControlRejection()
                return
            }
            _ = displayEvidenceOwner.observeStart(
                Self.displayEvidenceStart(from: control)
            )
        case .reconfigure:
            guard let route = Self.route(from: control) else {
                _ = displayEvidenceOwner.observeReconfigure(
                    nil,
                    routeAccepted: false
                )
                status.recordControlRejection()
                return
            }
            let accepted = recoveryOwner.reconfigure(route)
            _ = displayEvidenceOwner.observeReconfigure(
                Self.displayEvidenceCandidate(
                    from: control,
                    replacementRoute: route.identity
                ),
                routeAccepted: accepted
            )
            guard accepted else {
                status.recordControlRejection()
                return
            }
        case .requestIdr:
            guard let identity = matchingRoute(for: control),
                  recoveryOwner.requestKeyframe(route: identity)
            else {
                status.recordControlRejection()
                return
            }
        case .stopCapture:
            guard let identity = matchingRoute(for: control),
                  recoveryOwner.stop(route: identity)
            else {
                status.recordControlRejection()
                return
            }
        }
    }

    /// Nonterminal sleep seam. It rejects new route work, drains any admitted
    /// control, then stops and flushes the current SCK/VT route.
    @discardableResult
    func pauseMediaAndFlushForSleep() -> Bool {
        recoveryOwner.pauseAndFlushForSleep()
    }

    /// Atomically binds the matching suspended epoch to media ingress resume
    /// and its bounded convergence window. Callers receive only exact epoch +
    /// success; timeout, unavailable and route failure all fail closed.
    @discardableResult
    func beginMediaRecoveryAfterWake(
        epoch: UInt64,
        completion: @escaping MediaRecoveryCompletion
    ) -> Bool {
        let suspended = recoveryOwner.snapshot()
        guard suspended.status == .suspended,
              suspended.epoch == epoch,
              recoveryOwner.resumeAfterWake()
        else { return false }
        return recoveryPollingOwner.start(
            epoch: epoch,
            completion: { completedEpoch, outcome in
                completion(completedEpoch, outcome == .converged)
            }
        )
    }

    /// Consumes only already-sanitized Rust media diagnostics. Non-media
    /// events are ignored; malformed or stale media diagnostics are counted
    /// but never mutate another route's telemetry.
    func consume(_ event: HostCoreEvent) {
        condition.lock()
        guard case .active = state else {
            condition.unlock()
            return
        }
        diagnosticsInFlight += 1
        condition.unlock()
        defer {
            condition.lock()
            diagnosticsInFlight -= 1
            condition.broadcast()
            condition.unlock()
        }

        switch event.eventType {
        case "mediaDisplayReconfigureStarted":
            guard let started = event.displayReconfigureStarted else {
                status.recordDiagnosticRejection()
                return
            }
            _ = displayEvidenceOwner.accept(
                HostDisplayReconfigureEvidenceMarker(
                    generation: started.generation,
                    displayID: started.displayID,
                    previousDisplayRevision:
                        started.previousDisplayRevision,
                    previousConnectionEpoch:
                        started.previousConnectionEpoch,
                    previousCodecEpoch: started.previousCodecEpoch
                )
            )
            requestCapabilityRefreshForDisplayReconfigure()
        case "mediaDiagnostic":
            guard let diagnostic = event.mediaDiagnostic else {
                status.recordDiagnosticRejection()
                return
            }
            consume(diagnostic)
        case "mediaQueueDiagnostic":
            guard let diagnostic = event.mediaQueueDiagnostic else {
                status.recordDiagnosticRejection()
                return
            }
            consume(diagnostic)
        case "mediaWriterDiagnostic":
            guard let diagnostic = event.mediaWriterDiagnostic else {
                status.recordDiagnosticRejection()
                return
            }
            consume(diagnostic)
        case "mediaNetworkDiagnostic":
            guard let diagnostic = event.mediaNetworkDiagnostic else {
                status.recordDiagnosticRejection()
                return
            }
            consume(diagnostic)
        case "mediaTransportDiagnostic":
            guard let diagnostic = event.mediaTransportDiagnostic else {
                status.recordDiagnosticRejection()
                return
            }
            consume(diagnostic)
        default:
            return
        }
    }

    func snapshot() -> HostAgentMediaPipelineSnapshot {
        condition.lock()
        let lifecycleStatus: HostAgentMediaPipelineLifecycleStatus
        switch state {
        case .idle: lifecycleStatus = .idle
        case .active: lifecycleStatus = .active
        case .cancelling: lifecycleStatus = .cancelling
        case .cancelled: lifecycleStatus = .cancelled
        }
        condition.unlock()
        return status.snapshot(
            lifecycleStatus: lifecycleStatus,
            controlIngress: controlDeliveryGate.snapshot(),
            recovery: recoveryOwner.snapshot(),
            recoveryPolling: recoveryPollingOwner.stateSnapshot(),
            displayRecoveryEvidence: displayEvidenceOwner.snapshot(),
            routeOwner: routeOwner.snapshot(),
            liveLog: liveLogCoordinator.snapshot()
        )
    }

    /// Terminal and idempotent. Stops new periodic samples, drains SCK/VT so
    /// the final route record is written, then seals the log coordinator before
    /// invalidating weak runtime access.
    func cancelAndWait() {
        condition.lock()
        switch state {
        case .cancelled:
            condition.unlock()
            return
        case .cancelling:
            while case .cancelling = state {
                condition.wait()
            }
            condition.unlock()
            return
        case .idle, .active:
            state = .cancelling
            let task = capabilityTask
            while diagnosticsInFlight > 0 {
                condition.wait()
            }
            condition.unlock()
            task?.cancel()
        }

        controlDeliveryGate.cancelAndWait()
        displayEvidenceOwner.cancelAndWait()
        recoveryPollingOwner.cancelAndWait()
        liveLogPollingOwner.cancel()
        recoveryOwner.cancelAndWait()
        liveLogCoordinator.cancel()
        runtimeBinding.cancel()

        condition.lock()
        while capabilityInFlight {
            condition.wait()
        }
        capabilityTask = nil
        condition.unlock()
        status.recordCancelled()
        condition.lock()
        state = .cancelled
        condition.broadcast()
        condition.unlock()
    }

    /// A display-mode switch can raise the physical-pixel envelope above the
    /// one advertised at process startup. Rust keeps retrying the replacement
    /// route while its reconfigure provenance is pending, so refresh the
    /// native adapter envelope as soon as that authoritative marker arrives.
    /// Multiple switches during a probe are coalesced into one more pass so
    /// the last observed display mode cannot be stranded behind stale limits.
    private func requestCapabilityRefreshForDisplayReconfigure() {
        condition.lock()
        guard case .active = state else {
            condition.unlock()
            return
        }
        if capabilityInFlight {
            capabilityRefreshPending = true
            condition.unlock()
            return
        }
        capabilityInFlight = true
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCapabilityWork()
        }
        capabilityTask = task
        condition.unlock()
    }

    private func runCapabilityWork() async {
        while true {
            await discoverAndPublishCapabilities()
            let repeatForNewDisplay = finishCapabilityPass(
                cancelled: Task.isCancelled
            )
            guard repeatForNewDisplay else { return }
        }
    }

    private func finishCapabilityPass(cancelled: Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let repeatForNewDisplay = if case .active = state {
            capabilityRefreshPending && !cancelled
        } else {
            false
        }
        capabilityRefreshPending = false
        if !repeatForNewDisplay {
            capabilityInFlight = false
            capabilityTask = nil
            condition.broadcast()
        }
        return repeatForNewDisplay
    }

    private func discoverAndPublishCapabilities() async {
        status.recordCapabilityProbeStarted()
        guard let target = HostAgentDisplayCapabilityTarget.current() else {
            status.recordCapabilityFailure()
            return
        }
        guard let discovered = await HostHardwareEncoderCapabilityDiscovery.discover(
            target: target
        ), !Task.isCancelled else {
            status.recordCapabilityFailure()
            return
        }
        guard let maxWidth = UInt32(exactly: discovered.maxWidth),
              let maxHeight = UInt32(exactly: discovered.maxHeight),
              let maxFPS = UInt32(exactly: discovered.maxFPS)
        else {
            status.recordCapabilityFailure()
            return
        }
        do {
            try runtimeBinding.setMediaCapabilities(HostEncoderCapabilities(
                h264Hardware: discovered.h264Hardware,
                h265Hardware: discovered.h265Hardware,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                maxFPS: maxFPS
            ))
            status.recordCapabilitiesReady()
        } catch {
            status.recordCapabilityFailure()
        }
    }

    private func matchingRoute(
        for control: HostMediaControl
    ) -> HostMediaPipelineRouteIdentity? {
        for route in recoveryOwner.routeIdentities() {
            if route.connectionEpoch == control.connectionEpoch
                && route.codecEpoch == control.codecEpoch
                && route.displayID == control.displayID
                && (control.displayRevision == 0
                    || route.displayRevision == control.displayRevision) {
                return route
            }
        }
        return nil
    }

    private func diagnosticRoute(
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        displayID: UInt64,
        displayRevision: UInt64,
        codec: HostPipelineCodec? = nil
    ) -> HostMediaPipelineRouteIdentity? {
        routeOwner.routeIdentities(includingRetainedTelemetry: true).first { route in
            route.connectionEpoch == connectionEpoch
                && route.codecEpoch == codecEpoch
                && route.displayID == displayID
                && route.displayRevision == displayRevision
                && (codec == nil || route.codec == codec)
        }
    }

    private func consume(_ diagnostic: HostMediaDiagnostic) {
        let codec: HostPipelineCodec = diagnostic.codec == .h264 ? .h264 : .h265
        guard diagnostic.framing == .avcc,
              let route = diagnosticRoute(
                connectionEpoch: diagnostic.connectionEpoch,
                codecEpoch: diagnostic.codecEpoch,
                displayID: diagnostic.displayID,
                displayRevision: diagnostic.displayRevision,
                codec: codec
              ),
              diagnostic.kind != .refreshKeyframeDispatched
                || (diagnostic.isKeyframe && diagnostic.hasParameterSets)
        else {
            status.recordDiagnosticRejection()
            return
        }
        status.recordMediaDiagnostic(kind: diagnostic.kind, route: route)
    }

    private func consume(_ diagnostic: HostMediaQueueDiagnostic) {
        guard let route = diagnosticRoute(
            connectionEpoch: diagnostic.connectionEpoch,
            codecEpoch: diagnostic.codecEpoch,
            displayID: diagnostic.displayID,
            displayRevision: diagnostic.displayRevision
        ) else {
            status.recordDiagnosticRejection()
            return
        }
        status.recordTelemetryUpdate(accepted: routeOwner.recordEncodedQueueDepth(
            route: route,
            current: Int(diagnostic.currentDepth),
            maximum: Int(diagnostic.maximumDepth),
            capacity: Int(diagnostic.capacity),
            finalized: diagnostic.kind == .routeStopped
        ))
    }

    private func consume(_ diagnostic: HostMediaWriterDiagnostic) {
        guard let route = diagnosticRoute(
            connectionEpoch: diagnostic.connectionEpoch,
            codecEpoch: diagnostic.codecEpoch,
            displayID: diagnostic.displayID,
            displayRevision: diagnostic.displayRevision
        ) else {
            status.recordDiagnosticRejection()
            return
        }
        status.recordTelemetryUpdate(accepted: routeOwner.recordWriterTiming(
            route: route,
            cycles: diagnostic.cycles,
            subscriberDispatches: diagnostic.subscriberDispatches,
            dispatchWallTotalUS: diagnostic.dispatchWallTotalUS,
            maximumDispatchWallUS: diagnostic.maximumDispatchWallUS,
            confirmationWaitTotalUS: diagnostic.confirmationWaitTotalUS,
            maximumConfirmationWaitUS: diagnostic.maximumConfirmationWaitUS,
            completedConfirmations: diagnostic.completedConfirmations,
            timedOutConfirmations: diagnostic.timedOutConfirmations,
            finalized: diagnostic.kind == .routeStopped
        ))
    }

    private func consume(_ diagnostic: HostMediaNetworkDiagnostic) {
        guard let route = diagnosticRoute(
            connectionEpoch: diagnostic.connectionEpoch,
            codecEpoch: diagnostic.codecEpoch,
            displayID: diagnostic.displayID,
            displayRevision: diagnostic.displayRevision
        ) else {
            status.recordDiagnosticRejection()
            return
        }
        status.recordTelemetryUpdate(accepted: routeOwner.recordNetworkMetrics(
            route: route,
            subscriberCount: Int(diagnostic.subscriberCount),
            qosSubscriberCount: Int(diagnostic.qosSubscriberCount),
            delaySampledSubscribers: Int(diagnostic.delaySampledSubscribers),
            rttSampledSubscribers: Int(diagnostic.rttSampledSubscribers),
            responseDelayedSubscribers: Int(diagnostic.responseDelayedSubscribers),
            networkDelayMS: diagnostic.worstNetworkDelayMS.map(Int.init),
            roundTripTimeMS: diagnostic.worstRTTMS.map(Int.init),
            finalized: diagnostic.kind == .routeStopped
        ))
    }

    private func consume(_ diagnostic: HostMediaTransportDiagnostic) {
        guard let route = diagnosticRoute(
            connectionEpoch: diagnostic.connectionEpoch,
            codecEpoch: diagnostic.codecEpoch,
            displayID: diagnostic.displayID,
            displayRevision: diagnostic.displayRevision
        ) else {
            status.recordDiagnosticRejection()
            return
        }
        status.recordTelemetryUpdate(accepted: routeOwner.recordTransportMetrics(
            route: route,
            subscriberCount: Int(diagnostic.subscriberCount),
            directSubscribers: Int(diagnostic.directSubscribers),
            relaySubscribers: Int(diagnostic.relaySubscribers),
            unknownSubscribers: Int(diagnostic.unknownSubscribers),
            finalized: diagnostic.kind == .routeStopped
        ))
    }

    private static func route(
        from control: HostMediaControl
    ) -> HostMediaPipelineRoute? {
        guard let identity = exactIdentity(from: control),
              let width = control.width,
              let height = control.height,
              let framesPerSecond = control.framesPerSecond,
              (16...16_384).contains(width),
              (16...16_384).contains(height),
              (1...240).contains(framesPerSecond),
              control.displayID <= UInt64(Int.max)
        else { return nil }
        let pixelCount = UInt64(width) * UInt64(height)
        let fallbackBitRate = max(
            1_000_000,
            min(40_000_000, Int(min(
                UInt64(Int.max),
                pixelCount * UInt64(framesPerSecond) / 10
            )))
        )
        let bitRate: Int
        if let requested = control.bitRate {
            guard (100_000...100_000_000).contains(requested) else { return nil }
            bitRate = Int(requested)
        } else {
            bitRate = fallbackBitRate
        }
        return HostMediaPipelineRoute(
            identity: identity,
            configuration: HostMediaPipelineConfiguration(
                codec: identity.codec,
                displayIndex: Int(control.displayID),
                width: Int(width),
                height: Int(height),
                framesPerSecond: Int(framesPerSecond),
                bitRate: bitRate
            )
        )
    }

    private static func displayEvidenceMarker(
        from control: HostMediaControl
    ) -> HostDisplayReconfigureEvidenceMarker? {
        guard let provenance = control.displayReconfigure else { return nil }
        return HostDisplayReconfigureEvidenceMarker(
            generation: provenance.generation,
            displayID: control.displayID,
            previousDisplayRevision: provenance.previousDisplayRevision,
            previousConnectionEpoch: provenance.previousConnectionEpoch,
            previousCodecEpoch: provenance.previousCodecEpoch
        )
    }

    private static func displayEvidenceStart(
        from control: HostMediaControl
    ) -> HostDisplayReconfigureEvidenceStart? {
        guard let marker = displayEvidenceMarker(from: control) else {
            return nil
        }
        return HostDisplayReconfigureEvidenceStart(
            marker: marker,
            connectionEpoch: control.connectionEpoch,
            codecEpoch: control.codecEpoch,
            displayID: control.displayID,
            displayRevision: control.displayRevision
        )
    }

    private static func displayEvidenceCandidate(
        from control: HostMediaControl,
        replacementRoute: HostMediaPipelineRouteIdentity
    ) -> HostDisplayReconfigureEvidenceCandidate? {
        guard let marker = displayEvidenceMarker(from: control) else {
            return nil
        }
        return HostDisplayReconfigureEvidenceCandidate(
            marker: marker,
            replacementRoute: replacementRoute
        )
    }

    private static func exactIdentity(
        from control: HostMediaControl
    ) -> HostMediaPipelineRouteIdentity? {
        guard control.connectionEpoch > 0,
              control.codecEpoch > 0,
              control.displayRevision > 0,
              let codec = control.codec
        else { return nil }
        let pipelineCodec: HostPipelineCodec = codec == .h264 ? .h264 : .h265
        return HostMediaPipelineRouteIdentity(
            connectionEpoch: control.connectionEpoch,
            codecEpoch: control.codecEpoch,
            displayID: control.displayID,
            displayRevision: control.displayRevision,
            codec: pipelineCodec
        )
    }
}

private final class HostAgentMediaRuntimeBinding: @unchecked Sendable {
    private let lock = NSLock()
    private weak var lifetime: HostAgentProcessLifetime?
    private var hostInstanceID: String?
    private var cancelled = false

    func bind(
        lifetime: HostAgentProcessLifetime,
        hostInstanceID: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled,
              self.lifetime == nil,
              !hostInstanceID.isEmpty
        else { return false }
        self.lifetime = lifetime
        self.hostInstanceID = hostInstanceID
        return true
    }

    func setMediaCapabilities(
        _ capabilities: HostEncoderCapabilities
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled,
              let lifetime,
              let hostInstanceID
        else { throw HostAgentMediaRuntimeBindingError.unavailable }
        try lifetime.setMediaCapabilities(
            hostInstanceID: hostInstanceID,
            capabilities: capabilities
        )
    }

    func submit(
        route: HostMediaPipelineRouteIdentity,
        unit: HostMediaAccessUnit
    ) -> HostMediaPipelineSubmissionDisposition {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled,
              let lifetime,
              let hostInstanceID
        else {
            return .dropped(reason: .shutdown, requiresKeyframeRecovery: false)
        }
        let codec: HostMediaCodec = route.codec == .h264 ? .h264 : .h265
        do {
            try lifetime.submit(accessUnit: HostEncodedAccessUnit(
                hostInstanceID: hostInstanceID,
                connectionEpoch: route.connectionEpoch,
                codecEpoch: route.codecEpoch,
                displayID: route.displayID,
                displayRevision: route.displayRevision,
                codec: codec,
                framing: .avcc,
                presentationTimeUS: unit.presentationTimeUS,
                isKeyframe: unit.isKeyframe,
                hasParameterSets: unit.hasParameterSets,
                data: unit.data
            ))
            return .accepted
        } catch let error as HostControlError {
            return .dropped(
                reason: Self.dropReason(error.mediaSubmissionDropReason),
                requiresKeyframeRecovery: error.requiresMediaKeyframeRecovery
            )
        } catch {
            return .dropped(reason: nil, requiresKeyframeRecovery: false)
        }
    }

    func reportEncoderState(
        route: HostMediaPipelineRouteIdentity,
        state: HostEncoderRuntimeState
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled,
              let lifetime,
              let hostInstanceID
        else { return }
        let codec: HostMediaCodec = route.codec == .h264 ? .h264 : .h265
        try? lifetime.reportEncoderState(
            hostInstanceID: hostInstanceID,
            connectionEpoch: route.connectionEpoch,
            codecEpoch: route.codecEpoch,
            codec: codec,
            hardwareAccelerated: state.hardwareAccelerated,
            softwareFallback: state.softwareFallback,
            encoderID: state.encoderID
        )
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lifetime = nil
        hostInstanceID = nil
        lock.unlock()
    }

    private static func dropReason(
        _ reason: HostMediaSubmissionDropReason?
    ) -> HostMediaDropReason? {
        switch reason {
        case .networkBackpressure: return .networkBackpressure
        case .reconfigure: return .reconfigure
        case .invalidFrame: return .invalidFrame
        case .shutdown: return .shutdown
        case nil: return nil
        }
    }
}

private enum HostAgentMediaRuntimeBindingError: Error {
    case unavailable
}

private enum HostAgentDisplayCapabilityTarget {
    static func current() -> HostHardwareEncoderCapabilityTarget? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success,
              count > 0
        else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return nil
        }
        let active = displays.prefix(Int(count))
        // Keep the encoder capability envelope in the same physical-pixel
        // units as Rust's display inventory. `CGDisplayPixelsWide/High` expose
        // the logical 2048x1152 size for a 4096x2304 Retina mode, which makes
        // the native route fail closed before `startCapture` is emitted.
        let pixelSizes = active.map { display -> (width: Int, height: Int) in
            guard let mode = CGDisplayCopyDisplayMode(display),
                  mode.pixelWidth > 0,
                  mode.pixelHeight > 0
            else {
                return (
                    width: CGDisplayPixelsWide(display),
                    height: CGDisplayPixelsHigh(display)
                )
            }
            return (width: mode.pixelWidth, height: mode.pixelHeight)
        }
        let width = pixelSizes.map(\.width).max() ?? 0
        let height = pixelSizes.map(\.height).max() ?? 0
        let maximumFPS = active.map { display -> Int in
            let refresh = CGDisplayCopyDisplayMode(display)?.refreshRate ?? 0
            return refresh > 0 ? Int(refresh.rounded(.down)) : 60
        }.max() ?? 60
        return HostHardwareEncoderCapabilityTarget(
            width: width,
            height: height,
            maximumFramesPerSecond: min(60, max(1, maximumFPS))
        )
    }
}

private final class HostAgentMediaPipelineStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var capabilityStatus: HostAgentMediaCapabilityStatus = .notStarted
    private var capabilityFailures: UInt64 = 0
    private var pipelineStartFailures: UInt64 = 0
    private var pipelineRuntimeFailures: UInt64 = 0
    private var rejectedControls: UInt64 = 0
    private var acceptedMediaDiagnostics: UInt64 = 0
    private var acceptedTelemetryUpdates: UInt64 = 0
    private var rejectedDiagnostics: UInt64 = 0
    private var lastMediaDiagnosticKind: HostMediaDiagnostic.Kind?
    private var lastMediaDiagnosticRoute: HostMediaPipelineRouteIdentity?

    func recordCapabilityProbeStarted() {
        lock.lock()
        capabilityStatus = .probing
        lock.unlock()
    }

    func recordCapabilitiesReady() {
        lock.lock()
        capabilityStatus = .ready
        lock.unlock()
    }

    func recordCapabilityFailure() {
        lock.lock()
        capabilityStatus = .failed
        incrementSaturating(&capabilityFailures)
        lock.unlock()
    }

    func record(failure: HostMediaPipelineRouteFailure) {
        lock.lock()
        switch failure {
        case .startFailed:
            incrementSaturating(&pipelineStartFailures)
        case .runtimeFailed:
            incrementSaturating(&pipelineRuntimeFailures)
        }
        lock.unlock()
    }

    func recordControlRejection() {
        lock.lock()
        incrementSaturating(&rejectedControls)
        lock.unlock()
    }

    func recordMediaDiagnostic(
        kind: HostMediaDiagnostic.Kind,
        route: HostMediaPipelineRouteIdentity
    ) {
        lock.lock()
        incrementSaturating(&acceptedMediaDiagnostics)
        lastMediaDiagnosticKind = kind
        lastMediaDiagnosticRoute = route
        lock.unlock()
    }

    func recordTelemetryUpdate(accepted: Bool) {
        lock.lock()
        if accepted {
            incrementSaturating(&acceptedTelemetryUpdates)
        } else {
            incrementSaturating(&rejectedDiagnostics)
        }
        lock.unlock()
    }

    func recordDiagnosticRejection() {
        lock.lock()
        incrementSaturating(&rejectedDiagnostics)
        lock.unlock()
    }

    func recordCancelled() {
        lock.lock()
        capabilityStatus = .cancelled
        lock.unlock()
    }

    func snapshot(
        lifecycleStatus: HostAgentMediaPipelineLifecycleStatus,
        controlIngress: HostAgentMediaControlDeliverySnapshot,
        recovery: HostMediaPipelineRecoverySnapshot,
        recoveryPolling: HostMediaPipelineRecoveryPollingState,
        displayRecoveryEvidence: HostDisplayReconfigureEvidenceState,
        routeOwner: HostMediaPipelineRouteOwnerSnapshot,
        liveLog: HostMediaPipelineLiveLogCoordinatorSnapshot
    ) -> HostAgentMediaPipelineSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HostAgentMediaPipelineSnapshot(
            lifecycleStatus: lifecycleStatus,
            capabilityStatus: capabilityStatus,
            capabilityFailures: capabilityFailures,
            pipelineStartFailures: pipelineStartFailures,
            pipelineRuntimeFailures: pipelineRuntimeFailures,
            rejectedControls: rejectedControls,
            acceptedMediaDiagnostics: acceptedMediaDiagnostics,
            acceptedTelemetryUpdates: acceptedTelemetryUpdates,
            rejectedDiagnostics: rejectedDiagnostics,
            lastMediaDiagnosticKind: lastMediaDiagnosticKind,
            lastMediaDiagnosticRoute: lastMediaDiagnosticRoute,
            controlIngress: controlIngress,
            recovery: recovery,
            recoveryPolling: recoveryPolling,
            displayRecoveryEvidence: displayRecoveryEvidence,
            routeOwner: routeOwner,
            liveLog: liveLog
        )
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}
