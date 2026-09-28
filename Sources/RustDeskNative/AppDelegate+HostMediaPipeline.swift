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
    func startHostMediaPipeline(control: HostMediaControl) {
        guard let selectedCodec = control.codec else {
            hostErrorText = "Host 媒体 codec 缺失，已拒绝开始采集。"
            refreshHomeUI()
            return
        }
        let pipelineCodec: HostPipelineCodec
        switch selectedCodec {
        case .h264: pipelineCodec = .h264
        case .h265: pipelineCodec = .h265
        }
        guard hostRuntimeActive, let width = control.width, let height = control.height,
            let framesPerSecond = control.framesPerSecond, width > 0, height > 0,
            framesPerSecond > 0, control.displayID <= UInt64(Int.max), let snapshot = hostSnapshot,
            let client = hostClient
        else {
            hostErrorText = "Host 媒体参数无效，已拒绝开始采集。"
            refreshHomeUI()
            return
        }
        if snapshot.activeSession == nil
            || !HostActiveAquaSessionAuthority.currentSessionIsAvailable()
        {
            stopHostMediaPipeline()
            hostMediaRoute = control
            hostMediaSuspendedForSessionUnavailable = true
            hostMediaStatusText = "当前 Mac 会话不可用，画面采集已暂停"
            recordHostRuntimeStateEvidence(force: true)
            refreshHomeUI()
            return
        }
        stopHostMediaPipeline()
        hostMediaGeneration &+= 1
        let generation = hostMediaGeneration
        let fallbackBitRate = max(
            1_000_000, min(40_000_000, Int(width) * Int(height) * Int(framesPerSecond) / 10))
        let requestedBitRate = Int(control.bitRate ?? 0)
        let bitRate = requestedBitRate > 0 ? requestedBitRate : fallbackBitRate
        let route = control
        let pipelineConfiguration = HostMediaPipelineConfiguration(
            codec: pipelineCodec, displayIndex: Int(control.displayID), width: Int(width),
            height: Int(height), framesPerSecond: Int(framesPerSecond), bitRate: bitRate)
        let telemetry = HostMediaTelemetry(configuration: pipelineConfiguration)
        telemetry.markDropReasonsInstrumented([.networkBackpressure])
        let evidenceWriter: HostMediaTelemetryEvidenceWriter?
        do { evidenceWriter = try HostMediaTelemetryEvidenceWriter.configured() } catch {
            evidenceWriter = nil
            fputs("Host telemetry evidence output is invalid or already exists.\n", stderr)
        }
        let liveLogWriter: HostMediaTelemetryLiveLogWriter?
        do { liveLogWriter = try HostMediaTelemetryLiveLogWriter.makeDefault() } catch {
            liveLogWriter = nil
            fputs("Host media live log could not be created.\n", stderr)
        }
        let pipelineReference = HostMediaPipelineReference()
        let pipeline = HostMediaPipeline(
            configuration: pipelineConfiguration, telemetry: telemetry,
            onAccessUnit: { [weak client] accessUnit in
                guard let client else { return }
                let packetCodec: HostMediaCodec = accessUnit.codec == .h264 ? .h264 : .h265
                telemetry.record(
                    .sendSubmit, presentationTimeUS: accessUnit.presentationTimeUS,
                    byteCount: accessUnit.data.count)
                do {
                    try client.submit(
                        accessUnit: HostEncodedAccessUnit(
                            hostInstanceID: snapshot.hostInstanceId,
                            connectionEpoch: route.connectionEpoch, codecEpoch: route.codecEpoch,
                            displayID: route.displayID, displayRevision: route.displayRevision,
                            codec: packetCodec, framing: .avcc,
                            presentationTimeUS: accessUnit.presentationTimeUS,
                            isKeyframe: accessUnit.isKeyframe,
                            hasParameterSets: accessUnit.hasParameterSets, data: accessUnit.data))
                    telemetry.record(
                        .sendAccepted, presentationTimeUS: accessUnit.presentationTimeUS,
                        byteCount: accessUnit.data.count)
                } catch let error as HostControlError where error.isExpectedMediaDrop {
                    // Queue backpressure may reject an encoded reference
                    // packet. Reset this route's encoder generation so old
                    // callbacks stop and the replacement begins with an IDR.
                    telemetry.record(
                        .sendDropped, presentationTimeUS: accessUnit.presentationTimeUS,
                        byteCount: accessUnit.data.count)
                    if let reason = error.mediaSubmissionDropReason {
                        telemetry.recordDrop(reason.telemetryReason)
                    } else {
                        telemetry.recordUnclassifiedDrop()
                    }
                    if error.requiresMediaKeyframeRecovery {
                        pipelineReference.recoverFromEncodedPacketDrop()
                    }
                } catch {
                    telemetry.record(
                        .sendDropped, presentationTimeUS: accessUnit.presentationTimeUS,
                        byteCount: accessUnit.data.count)
                    if let hostError = error as? HostControlError,
                        let reason = hostError.mediaSubmissionDropReason
                    {
                        telemetry.recordDrop(reason.telemetryReason)
                    } else {
                        telemetry.recordUnclassifiedDrop()
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard self?.hostMediaGeneration == generation else { return }
                        self?.hostErrorText = self?.sanitizedHostError(error) ?? ""
                        self?.refreshHomeUI()
                    }
                }
            },
            onState: { [weak client] state in
                try? client?.reportEncoderState(
                    hostInstanceID: snapshot.hostInstanceId, connectionEpoch: route.connectionEpoch,
                    codecEpoch: route.codecEpoch, codec: selectedCodec,
                    hardwareAccelerated: state.hardwareAccelerated,
                    softwareFallback: state.softwareFallback, encoderID: state.encoderID)
            },
            onError: { [weak self] _ in
                DispatchQueue.main.async {
                    guard self?.hostMediaGeneration == generation else { return }
                    self?.hostErrorText = "屏幕采集或硬件编码暂时不可用。"
                    self?.refreshHomeUI()
                }
            })
        pipelineReference.bind(pipeline)
        hostMediaPipeline = pipeline
        hostMediaEvidenceWriter = evidenceWriter
        hostMediaLiveLogWriter = liveLogWriter
        hostMediaRoute = control
        hostMediaStatusText = "正在采集并编码画面…"
        if let liveLogWriter {
            do {
                try liveLogWriter.record(snapshot: telemetry.snapshot(), event: .routeStarted)
            } catch {
                hostMediaLiveLogWriter = nil
                fputs("Host media live log write failed.\n", stderr)
            }
        }
        recordHostRuntimeStateEvidence(force: true)
        Task { [weak self, weak pipeline] in
            guard let self, let pipeline else { return }
            do { try await pipeline.start() } catch {
                await pipeline.stop()
                if let evidenceWriter {
                    do { try evidenceWriter.write(snapshot: telemetry.snapshot()) } catch {
                        fputs("Host telemetry evidence write failed.\n", stderr)
                    }
                }
                if let liveLogWriter {
                    do {
                        try liveLogWriter.record(
                            snapshot: telemetry.snapshot(), event: .routeStartFailed)
                    } catch { fputs("Host media live log write failed.\n", stderr) }
                }
                await MainActor.run {
                    guard self.hostMediaGeneration == generation else { return }
                    self.hostMediaPipeline = nil
                    self.hostMediaEvidenceWriter = nil
                    self.hostMediaLiveLogWriter = nil
                    self.hostMediaRoute = nil
                    self.hostMediaStatusText = nil
                    self.hostErrorText = "无法开始屏幕采集，请检查屏幕录制权限。"
                    self.recordHostRuntimeStateEvidence(force: true)
                    self.refreshHomeUI()
                }
            }
        }
    }

    func suspendHostMediaPipelineForSessionUnavailable() {
        guard !hostMediaSuspendedForSessionUnavailable || hostMediaPipeline != nil else { return }
        guard let route = hostMediaRoute else { return }
        hostMediaSuspendedForSessionUnavailable = true
        guard let pipeline = hostMediaPipeline else {
            hostMediaStatusText = "当前 Mac 会话不可用，画面采集已暂停"
            recordHostRuntimeStateEvidence(force: true)
            return
        }

        hostMediaGeneration &+= 1
        let evidenceWriter = hostMediaEvidenceWriter
        let liveLogWriter = hostMediaLiveLogWriter
        hostMediaPipeline = nil
        hostMediaEvidenceWriter = nil
        hostMediaLiveLogWriter = nil
        hostMediaStatusText = "当前 Mac 会话不可用，画面采集已暂停"
        recordHostRuntimeStateEvidence(force: true)
        pipeline.cancel()
        Task {
            await pipeline.stop()
            if let evidenceWriter {
                do { try evidenceWriter.write(snapshot: pipeline.telemetry.snapshot()) } catch {
                    fputs("Host telemetry evidence write failed.\n", stderr)
                }
            }
            if let liveLogWriter {
                do {
                    try liveLogWriter.record(
                        snapshot: pipeline.telemetry.snapshot(), event: .captureSuspended)
                } catch { fputs("Host media live log write failed.\n", stderr) }
            }
        }
        // The Rust route remains authoritative while only the process-local
        // capture/encoder pipeline is stopped. This exact route is reused when
        // the same Aqua session becomes available again.
        hostMediaRoute = route
    }

    func resumeHostMediaPipelineAfterSessionRecovery() {
        guard hostMediaSuspendedForSessionUnavailable, hostMediaPipeline == nil,
            let route = hostMediaRoute
        else { return }
        hostMediaSuspendedForSessionUnavailable = false
        hostMediaStatusText = "当前 Mac 会话已恢复，正在恢复画面…"
        startHostMediaPipeline(control: route)
    }

    func stopHostMediaPipeline() {
        hostMediaGeneration &+= 1
        let pipeline = hostMediaPipeline
        let evidenceWriter = hostMediaEvidenceWriter
        let liveLogWriter = hostMediaLiveLogWriter
        hostMediaPipeline = nil
        hostMediaEvidenceWriter = nil
        hostMediaLiveLogWriter = nil
        hostMediaRoute = nil
        hostMediaSuspendedForSessionUnavailable = false
        hostMediaStatusText = nil
        recordHostRuntimeStateEvidence(force: true)
        pipeline?.cancel()
        if let pipeline {
            Task {
                await pipeline.stop()
                if let evidenceWriter {
                    do { try evidenceWriter.write(snapshot: pipeline.telemetry.snapshot()) } catch {
                        fputs("Host telemetry evidence write failed.\n", stderr)
                    }
                }
                if let liveLogWriter {
                    do {
                        try liveLogWriter.record(
                            snapshot: pipeline.telemetry.snapshot(), event: .routeStopped)
                    } catch { fputs("Host media live log write failed.\n", stderr) }
                }
            }
        }
    }
}
