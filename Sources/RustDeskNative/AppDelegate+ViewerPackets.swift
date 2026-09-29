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
    static func consume(
        packet: CoreVideoPacket, decoder: LiveHEVCDecoder, metrics: PipelineMetrics,
        fallbackFPS: Double, recovery: CoreRecoveryCoordinator
    ) {
        let codec = packet.codec == .h265 ? "h265" : packet.codec == .h264 ? "h264" : "unknown"
        let declaredFormat: HEVCPacketFormat?
        let format: String
        switch packet.format {
        case .annexB:
            declaredFormat = .annexB
            format = "annex-b"
        case .avcc:
            declaredFormat = .avcc
            format = "avcc"
        case .mixed:
            declaredFormat = nil
            format = "mixed"
        case .unknown:
            declaredFormat = nil
            format = "unknown"
        }
        metrics.recordEncodedPacket(
            codec: codec, format: format, byteCount: packet.data.count, sequence: packet.sequence,
            timestampUS: packet.timestampUS, isKeyframe: packet.isKeyframe,
            containsVPS: packet.containsVPS, containsSPS: packet.containsSPS,
            containsPPS: packet.containsPPS, width: Int(packet.width), height: Int(packet.height))
        guard packet.codec == .h265, let declaredFormat else {
            metrics.recordDecodeError()
            return
        }
        do {
            let encoded = try HEVCEncodedPacket(data: packet.data, declaredFormat: declaredFormat)
            let sets = encoded.parameterSets
            guard encoded.isKeyframe == packet.isKeyframe, (sets[32] != nil) == packet.containsVPS,
                (sets[33] != nil) == packet.containsSPS, (sets[34] != nil) == packet.containsPPS
            else {
                metrics.recordDecodeError()
                return
            }
            try decoder.submit(
                encoded, sequence: Int64(clamping: packet.sequence),
                timestampUS: packet.timestampUS, fps: max(1, fallbackFPS))
        } catch let error as LiveHEVCDecoderError {
            switch error {
            case .waitingForParameterSets, .waitingForKeyframe:
                // Parameter sets and an IDR may legitimately arrive after transport setup.
                break
            case .referenceFrameDropped:
                requestRecoveryKeyframe(
                    display: packet.display, reason: "reference-frame-drop", metrics: metrics,
                    recovery: recovery)
            case .asynchronousDecodeFailure(let status):
                requestRecoveryKeyframe(
                    display: packet.display, reason: "decode-status-\(status)", metrics: metrics,
                    recovery: recovery)
            }
        } catch {
            metrics.recordDecodeError()
            fputs("live decode submit error: \(error)\n", stderr)
        }
    }

    static func requestRecoveryKeyframe(
        display: UInt32, reason: String, metrics: PipelineMetrics, recovery: CoreRecoveryCoordinator
    ) {
        let requested = recovery.requestKeyframe(display: display)
        if requested { metrics.recordKeyframeRequest() }
        fputs("live decoder reset reason=\(reason) keyframe-requested=\(requested)\n", stderr)
    }
}
