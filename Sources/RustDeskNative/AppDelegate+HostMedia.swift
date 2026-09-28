import AppKit
import ApplicationServices
import ConnectionCatalog
import CoreBridge
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import MetalKit
import VideoPipeline
import ViewerInput

extension AppDelegate {
    func handleHostCoreEvent(_ event: HostCoreEvent) {
        if let control = event.mediaControl { handleHostMediaControl(control) }
        if let diagnostic = event.mediaDiagnostic { handleHostMediaDiagnostic(diagnostic) }
        if let queueDiagnostic = event.mediaQueueDiagnostic {
            handleHostMediaQueueDiagnostic(queueDiagnostic)
        }
        if let writerDiagnostic = event.mediaWriterDiagnostic {
            handleHostMediaWriterDiagnostic(writerDiagnostic)
        }
        if let networkDiagnostic = event.mediaNetworkDiagnostic {
            handleHostMediaNetworkDiagnostic(networkDiagnostic)
        }
        if let transportDiagnostic = event.mediaTransportDiagnostic {
            handleHostMediaTransportDiagnostic(transportDiagnostic)
        }
        refreshHostSnapshot()
    }

    func configureHostMediaCapabilitiesIfNeeded(
        snapshot: HostCoreSnapshot, client: HostControlClient
    ) {
        guard !snapshot.hostInstanceId.isEmpty,
            hostMediaCapabilitiesInstanceID != snapshot.hostInstanceId
        else { return }
        hostMediaCapabilitiesInstanceID = snapshot.hostInstanceId
        guard let target = hostMediaCapabilityTarget() else {
            hostErrorText = "无法为当前显示器建立安全的视频硬件能力探测。"
            return
        }
        hostMediaCapabilitiesProbeTask?.cancel()
        let probeID = UUID()
        let instanceID = snapshot.hostInstanceId
        hostMediaCapabilitiesProbeID = probeID
        hostMediaStatusText = "正在验证本机硬件编码能力…"
        hostMediaCapabilitiesProbeTask = Task { @MainActor [weak self, weak client] in
            let discovered = await HostHardwareEncoderCapabilityDiscovery.discover(target: target)
            guard let self, self.hostMediaCapabilitiesProbeID == probeID, self.hostRuntimeActive,
                self.hostMediaCapabilitiesInstanceID == instanceID,
                self.hostSnapshot?.hostInstanceId == instanceID, self.hostClient === client,
                let client
            else { return }
            self.hostMediaCapabilitiesProbeTask = nil
            self.hostMediaCapabilitiesProbeID = nil
            guard let discovered else {
                self.hostMediaStatusText = nil
                self.hostErrorText = "当前显示器尺寸没有通过视频硬件编码首帧验证。"
                self.refreshHomeUI()
                return
            }
            do {
                try client.setMediaCapabilities(
                    hostInstanceID: instanceID,
                    capabilities: HostEncoderCapabilities(
                        h264Hardware: discovered.h264Hardware,
                        h265Hardware: discovered.h265Hardware,
                        maxWidth: UInt32(discovered.maxWidth),
                        maxHeight: UInt32(discovered.maxHeight), maxFPS: UInt32(discovered.maxFPS)))
                self.hostMediaStatusText = nil
            } catch {
                self.hostMediaStatusText = nil
                self.hostErrorText = self.sanitizedHostError(error)
            }
            self.refreshHomeUI()
        }
    }

    func hostMediaCapabilityTarget() -> HostHardwareEncoderCapabilityTarget? {
        let displays = NSScreen.screens.compactMap { screen -> (Int, Int, Int)? in
            guard
                let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                    as? NSNumber
            else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let width = CGDisplayPixelsWide(displayID)
            let height = CGDisplayPixelsHigh(displayID)
            guard width > 0, height > 0 else { return nil }
            return (width, height, screen.maximumFramesPerSecond)
        }
        guard !displays.isEmpty else { return nil }
        return HostHardwareEncoderCapabilityTarget(
            width: displays.map(\.0).max() ?? 0, height: displays.map(\.1).max() ?? 0,
            maximumFramesPerSecond: min(60, max(1, displays.map(\.2).max() ?? 60)))
    }

    func handleHostMediaControl(_ control: HostMediaControl) {
        switch control.command {
        case .startCapture: hostMediaStatusText = "控制端已订阅，正在准备画面…"
        case .stopCapture:
            guard hostMediaRoute?.matchesRoute(control) == true else { return }
            stopHostMediaPipeline()
        case .requestIdr:
            guard hostMediaRoute?.matchesRoute(control) == true else { return }
            if control.reason == "remoteRefresh" { hostMediaStatusText = "远端请求刷新，正在生成关键帧…" }
            hostMediaPipeline?.requestKeyframe()
        case .reconfigure: startHostMediaPipeline(control: control)
        }
    }

    func syncHostMediaCaptureAvailability(
        activeSession: HostActiveSession?, activeAquaSessionAvailable: Bool
    ) {
        guard hostMediaRoute != nil else { return }
        if activeSession == nil || !activeAquaSessionAvailable {
            suspendHostMediaPipelineForSessionUnavailable()
        } else {
            resumeHostMediaPipelineAfterSessionRecovery()
        }
    }

    func handleHostMediaDiagnostic(_ diagnostic: HostMediaDiagnostic) {
        guard let route = hostMediaRoute, diagnostic.matchesRoute(route) else { return }
        switch diagnostic.kind {
        case .firstPacketDispatched: hostMediaStatusText = "媒体帧已进入 Rust 发送链路"
        case .firstPacketAcknowledged: hostMediaStatusText = "媒体帧已获远端确认"
        case .refreshKeyframeDispatched:
            if diagnostic.isKeyframe && diagnostic.hasParameterSets {
                hostMediaStatusText = "刷新关键帧已发送"
            } else {
                hostErrorText = "刷新关键帧缺少必要的编码参数集。"
            }
        }
        refreshHomeUI()
    }

    func handleHostMediaQueueDiagnostic(_ diagnostic: HostMediaQueueDiagnostic) {
        guard let route = hostMediaRoute, diagnostic.matchesRoute(route),
            let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordEncodedQueueDepth(
            current: Int(diagnostic.currentDepth), maximum: Int(diagnostic.maximumDepth),
            capacity: Int(diagnostic.capacity), finalized: diagnostic.kind == .routeStopped)
    }

    func handleHostMediaWriterDiagnostic(_ diagnostic: HostMediaWriterDiagnostic) {
        guard let route = hostMediaRoute, diagnostic.matchesRoute(route),
            let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordWriterTiming(
            cycles: diagnostic.cycles, subscriberDispatches: diagnostic.subscriberDispatches,
            dispatchWallTotalUS: diagnostic.dispatchWallTotalUS,
            maximumDispatchWallUS: diagnostic.maximumDispatchWallUS,
            confirmationWaitTotalUS: diagnostic.confirmationWaitTotalUS,
            maximumConfirmationWaitUS: diagnostic.maximumConfirmationWaitUS,
            completedConfirmations: diagnostic.completedConfirmations,
            timedOutConfirmations: diagnostic.timedOutConfirmations,
            finalized: diagnostic.kind == .routeStopped)
    }

    func handleHostMediaNetworkDiagnostic(_ diagnostic: HostMediaNetworkDiagnostic) {
        guard let route = hostMediaRoute, diagnostic.matchesRoute(route),
            let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordNetworkMetrics(
            subscriberCount: Int(diagnostic.subscriberCount),
            qosSubscriberCount: Int(diagnostic.qosSubscriberCount),
            delaySampledSubscribers: Int(diagnostic.delaySampledSubscribers),
            rttSampledSubscribers: Int(diagnostic.rttSampledSubscribers),
            responseDelayedSubscribers: Int(diagnostic.responseDelayedSubscribers),
            networkDelayMS: diagnostic.worstNetworkDelayMS.map(Int.init),
            roundTripTimeMS: diagnostic.worstRTTMS.map(Int.init),
            finalized: diagnostic.kind == .routeStopped)
    }

    func handleHostMediaTransportDiagnostic(_ diagnostic: HostMediaTransportDiagnostic) {
        guard let route = hostMediaRoute, diagnostic.matchesRoute(route),
            let telemetry = hostMediaPipeline?.telemetry
        else { return }
        telemetry.recordTransportMetrics(
            subscriberCount: Int(diagnostic.subscriberCount),
            directSubscribers: Int(diagnostic.directSubscribers),
            relaySubscribers: Int(diagnostic.relaySubscribers),
            unknownSubscribers: Int(diagnostic.unknownSubscribers),
            finalized: diagnostic.kind == .routeStopped)
    }
}
