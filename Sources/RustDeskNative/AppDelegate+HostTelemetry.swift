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
    func observeHostAgentApplicationConcurrencyEvidence() {
        guard let activationView = hostAgentBackgroundActivationView else { return }
        let configRevision: UInt64?
        if case .coherent(let revision) = hostAgentRuntimeConfigurationCoherence {
            configRevision = revision
        } else {
            configRevision = nil
        }
        guard
            let observation = hostAgentApplicationConcurrencyObservationState.observe(
                projection: activationView.projection, coherentConfigRevision: configRevision,
                sourceToken: activationView.generation)
        else { return }
        recordHostAgentApplicationConcurrencyEvidence(observation, reaffirmation: false)
    }

    func reaffirmHostAgentApplicationConcurrencyEvidence() {
        guard
            let observation =
                hostAgentApplicationConcurrencyObservationState.reaffirmCurrentCoherentObservation()
        else { return }
        recordHostAgentApplicationConcurrencyEvidence(observation, reaffirmation: true)
    }

    func recordHostAgentApplicationConcurrencyEvidence(
        _ observation: HostAgentApplicationConcurrencyObservation, reaffirmation: Bool
    ) {
        guard let agentBootID = UUID(uuidString: observation.peerIdentity.agentBootID),
            agentBootID.uuidString.lowercased() == observation.peerIdentity.agentBootID
        else { return }

        let state: HostViewerConcurrencyHostState
        switch observation.state {
        case .readyZeroInbound: state = .readyZeroInbound
        case .inboundMediaActive: state = .inboundMediaActive
        case .disconnected: state = .disconnected
        }
        if reaffirmation {
            _ = hostViewerConcurrencyEvidenceOwner.reaffirmApplicationHostAgentRuntimeState(
                state: state, hostInstanceID: observation.peerIdentity.hostInstanceID,
                agentBootID: agentBootID, configRevision: observation.configRevision,
                agentBuildID: observation.peerIdentity.agentBuildID,
                agentProcessID: observation.peerIdentity.agentProcessID,
                agentProcessStartIdentitySHA256: observation.peerIdentity
                    .agentProcessStartIdentitySHA256, sourceGeneration: observation.sourceGeneration
            )
        } else {
            _ = hostViewerConcurrencyEvidenceOwner.observeApplicationHostAgentRuntimeState(
                state: state, hostInstanceID: observation.peerIdentity.hostInstanceID,
                agentBootID: agentBootID, configRevision: observation.configRevision,
                agentBuildID: observation.peerIdentity.agentBuildID,
                agentProcessID: observation.peerIdentity.agentProcessID,
                agentProcessStartIdentitySHA256: observation.peerIdentity
                    .agentProcessStartIdentitySHA256, sourceGeneration: observation.sourceGeneration
            )
        }
    }

    var hostAgentRuntimeConfigurationErrorText: String {
        switch hostAgentRuntimeConfigurationCoherence {
        case .waitingForLivePeer, .coherent: return ""
        case .evidenceUnavailable: return "无法核对后台 Host 的运行配置；已暂停就绪和控制。"
        case .staleConfiguration: return "后台 Host 仍在使用旧配置；已暂停就绪和控制，请关闭并重新开启“允许控制本机”。"
        case .identityMismatch: return "后台 Host 的运行身份与当前配置不一致；已暂停就绪和控制。"
        }
    }

    func hostMediaDiagnosticText() -> String {
        guard let snapshot = hostMediaPipeline?.telemetry.snapshot() else { return "" }
        let averageFPS = snapshot.validFrames > 1 ? String(format: "%.1f", snapshot.actualFPS) : "—"
        let recentFPS =
            snapshot.validFrames > 1 ? String(format: "%.1f", snapshot.recentCaptureFPS) : "—"
        let recentEncodedFPS =
            snapshot.encodedPackets > 1 ? String(format: "%.1f", snapshot.recentEncodedFPS) : "—"
        let recentSendAcceptedFPS =
            snapshot.sendAccepted > 1 ? String(format: "%.1f", snapshot.recentSendAcceptedFPS) : "—"
        let contentState: String
        switch snapshot.captureContentState {
        case .idle: contentState = "静止"
        case .lowMotion: contentState = "低活动"
        case .interactive: contentState = "交互"
        case .highMotion: contentState = "高活动"
        }
        let pressure: String
        switch snapshot.capturePressureLevel {
        case .none: pressure = "无"
        case .moderate: pressure = "中"
        case .severe: pressure = "高"
        }
        let pressureDetail = hostPressureDiagnosticText(snapshot)
        let updateState = snapshot.captureConfigurationUpdateInFlight ? " · 调档中" : ""
        let cadence = "\(snapshot.captureTargetFPS)/\(snapshot.captureAppliedFPS)"
        return "近5秒 采集/编码/入Rust \(recentFPS)/\(recentEncodedFPS)"
            + "/\(recentSendAcceptedFPS) FPS · 采集均值 \(averageFPS)"
            + "\n目标/已应用 \(cadence) · \(contentState) · 压力 \(pressure)"
            + "\(pressureDetail)\(updateState)"
    }

    func hostPressureDiagnosticText(_ snapshot: HostMediaTelemetrySnapshot) -> String {
        let observed: String
        switch snapshot.captureObservedPressureLevel {
        case .none: observed = "无"
        case .moderate: observed = "中"
        case .severe: observed = "高"
        }
        let causes = snapshot.capturePressureCauses.map { cause -> String in
            switch cause {
            case .thermalState: return "热状态 \(snapshot.thermalState ?? "未知")"
            case .lowPowerMode: return "低电量模式"
            case .encodeInFlight: return "编码在途 \(snapshot.encodeInFlight)"
            case .encodeLatency:
                return String(format: "编码延迟 %.1fms", snapshot.latestEncodeLatencyMS ?? 0)
            case .consecutiveSendDrops: return "连续入Rust失败 \(snapshot.consecutiveSendDrops)"
            case .recentSendDropRate:
                return String(
                    format: "入Rust丢弃 %.0f%%/%d", snapshot.recentSendDropRate * 100,
                    snapshot.recentSendOutcomeCount)
            case .encodedQueue:
                return "Rust队列 \(snapshot.encodedQueueDepth ?? 0)"
                    + "/\(snapshot.encodedQueueCapacity ?? 0)"
            case .networkDelay: return "网络延迟 \(snapshot.networkDelayMS ?? 0)ms"
            case .roundTripTime: return "RTT \(snapshot.roundTripTimeMS ?? 0)ms"
            case .responseDelayed: return "响应延迟订阅 \(snapshot.responseDelayedSubscribers)"
            }
        }
        if causes.isEmpty {
            return snapshot.captureObservedPressureLevel == snapshot.capturePressureLevel
                ? "" : "（当前 \(observed)，滞回恢复中）"
        }
        let prefix =
            snapshot.captureObservedPressureLevel == snapshot.capturePressureLevel
            ? "" : "当前 \(observed)："
        return "（\(prefix)\(causes.joined(separator: "，"))）"
    }

    func recordHostMediaLiveLog() {
        guard let writer = hostMediaLiveLogWriter, let telemetry = hostMediaPipeline?.telemetry
        else { return }
        do { try writer.record(snapshot: telemetry.snapshot()) } catch {
            hostMediaLiveLogWriter = nil
            fputs("Host media live log write failed.\n", stderr)
        }
    }

    func recordHostRuntimeStateEvidence(force: Bool = false) {
        guard let writer = hostRuntimeStateEvidenceWriter else { return }
        let usesLegacyHost =
            hostAgentBackgroundRegistrationStatus == .notRegistered
            && hostAgentBackgroundFlow == nil
        let backgroundPayload: HostAgentXPCWireSnapshotPayload? = {
            guard !usesLegacyHost,
                let projectionView = coherentHostAgentBackgroundActivationView?.projection,
                case .available(let projection) = projectionView.phase
            else { return nil }
            return projection.payload
        }()
        let snapshotObservedAt: UInt64? =
            usesLegacyHost
            ? hostSnapshot.flatMap { $0.observedAt > 0 ? $0.observedAt : nil }
            : backgroundPayload?.observedAt
        let runtimeActive = usesLegacyHost ? hostRuntimeActive : backgroundPayload != nil
        let hostState = usesLegacyHost ? hostSnapshot?.hostState : backgroundPayload?.hostState
        let registrationStatus =
            usesLegacyHost
            ? hostSnapshot?.registrationStatus : backgroundPayload?.registrationStatus
        let authenticatedConnectionCount =
            usesLegacyHost
            ? hostSnapshot?.authenticatedConnectionCount
            : backgroundPayload?.authenticatedConnectionCount
        let backgroundRouteActive = backgroundPayload?.activeSession != nil
        do {
            try writer.record(
                hostRuntimeActive: runtimeActive, hostState: hostState ?? "unavailable",
                registrationStatus: registrationStatus ?? "unavailable",
                hostSnapshotObservedAtUnixMilliseconds: snapshotObservedAt,
                authenticatedConnectionCount: authenticatedConnectionCount,
                mediaRouteActive: usesLegacyHost ? hostMediaRoute != nil : backgroundRouteActive,
                mediaPipelineActive: usesLegacyHost
                    ? hostMediaPipeline != nil : backgroundRouteActive, force: force)
        } catch {
            hostRuntimeStateEvidenceWriter = nil
            fputs("Host runtime-state evidence write failed.\n", stderr)
        }
    }
}
