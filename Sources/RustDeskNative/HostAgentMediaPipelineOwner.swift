import CoreBridge
import CoreGraphics
import Foundation
import VideoPipeline

/// Process-owned adapter from typed Rust media controls to the real
/// ScreenCaptureKit/VideoToolbox pipeline. It never touches AppDelegate/UI.
final class HostAgentMediaPipelineOwner: @unchecked Sendable {
    private enum State {
        case idle
        case active
        case cancelling
        case cancelled
    }

    private let condition = NSCondition()
    private let runtimeBinding: HostAgentMediaRuntimeBinding
    private let status: HostAgentMediaPipelineStatus
    private let routeOwner: HostMediaPipelineRouteOwner
    private var state: State = .idle
    private var capabilityTask: Task<Void, Never>?
    private var capabilityInFlight = false

    init() {
        let runtimeBinding = HostAgentMediaRuntimeBinding()
        let status = HostAgentMediaPipelineStatus()
        self.runtimeBinding = runtimeBinding
        self.status = status
        self.routeOwner = HostMediaPipelineRouteOwner(
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
        capabilityInFlight = true
        condition.unlock()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.discoverAndPublishCapabilities()
        }
        condition.lock()
        if capabilityInFlight {
            capabilityTask = task
        } else {
            task.cancel()
        }
        condition.unlock()
        return true
    }

    func handle(_ control: HostMediaControl) {
        condition.lock()
        guard case .active = state else {
            condition.unlock()
            return
        }
        condition.unlock()

        switch control.command {
        case .startCapture:
            // H4.1u has already recorded the pending route. Rust follows this
            // with the exact reconfigure that contains the encoder contract.
            return
        case .reconfigure:
            guard let route = Self.route(from: control),
                  routeOwner.reconfigure(route)
            else {
                status.recordControlRejection()
                return
            }
        case .requestIdr:
            guard let identity = matchingRoute(for: control),
                  routeOwner.requestKeyframe(route: identity)
            else {
                status.recordControlRejection()
                return
            }
        case .stopCapture:
            guard let identity = matchingRoute(for: control),
                  routeOwner.stop(route: identity)
            else {
                status.recordControlRejection()
                return
            }
        }
    }

    /// Terminal and idempotent. Drains SCK/VT before invalidating weak runtime
    /// access, then waits for a capability probe/set operation to finish.
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
            condition.unlock()
            task?.cancel()
        }

        routeOwner.cancelAndWait()
        runtimeBinding.cancel()

        condition.lock()
        while capabilityInFlight {
            condition.wait()
        }
        capabilityTask = nil
        state = .cancelled
        condition.broadcast()
        condition.unlock()
    }

    private func discoverAndPublishCapabilities() async {
        defer { finishCapabilityWork() }
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
        do {
            try runtimeBinding.setMediaCapabilities(HostEncoderCapabilities(
                h264Hardware: discovered.h264Hardware,
                h265Hardware: discovered.h265Hardware,
                maxWidth: UInt32(discovered.maxWidth),
                maxHeight: UInt32(discovered.maxHeight),
                maxFPS: UInt32(discovered.maxFPS)
            ))
            status.recordCapabilitiesReady()
        } catch {
            status.recordCapabilityFailure()
        }
    }

    private func finishCapabilityWork() {
        condition.lock()
        capabilityInFlight = false
        capabilityTask = nil
        condition.broadcast()
        condition.unlock()
    }

    private func matchingRoute(
        for control: HostMediaControl
    ) -> HostMediaPipelineRouteIdentity? {
        let snapshot = routeOwner.snapshot()
        for route in [snapshot.activeRoute, snapshot.desiredRoute].compactMap({ $0 }) {
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
        let width = active.map { CGDisplayPixelsWide($0) }.max() ?? 0
        let height = active.map { CGDisplayPixelsHigh($0) }.max() ?? 0
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
    private var capabilitiesReady = false
    private var capabilityFailures: UInt64 = 0
    private var pipelineFailures: UInt64 = 0
    private var rejectedControls: UInt64 = 0

    func recordCapabilitiesReady() {
        lock.lock()
        capabilitiesReady = true
        lock.unlock()
    }

    func recordCapabilityFailure() {
        lock.lock()
        incrementSaturating(&capabilityFailures)
        lock.unlock()
    }

    func record(failure _: HostMediaPipelineRouteFailure) {
        lock.lock()
        incrementSaturating(&pipelineFailures)
        lock.unlock()
    }

    func recordControlRejection() {
        lock.lock()
        incrementSaturating(&rejectedControls)
        lock.unlock()
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}
