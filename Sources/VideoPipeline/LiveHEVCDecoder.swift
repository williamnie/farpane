import Foundation

public enum LiveHEVCDecoderError: Error, CustomStringConvertible {
    case waitingForParameterSets
    case waitingForKeyframe
    case referenceFrameDropped
    case asynchronousDecodeFailure(OSStatus)

    public var description: String {
        switch self {
        case .waitingForParameterSets: return "waiting for HEVC VPS/SPS/PPS"
        case .waitingForKeyframe: return "waiting for HEVC keyframe after decoder reset"
        case .referenceFrameDropped: return "live HEVC reference frame dropped under decoder backpressure"
        case .asynchronousDecodeFailure(let status): return "VideoToolbox asynchronous decode failed: \(status)"
        }
    }
}

public final class LiveHEVCDecoder: @unchecked Sendable {
    private static let maximumPendingFrames = 2
    private let lock = NSLock()
    private let metrics: PipelineMetrics
    private let output: VideoToolboxDecoder.FrameHandler
    private var parameterSets: [UInt8: Data] = [:]
    private var decoder: VideoToolboxDecoder?
    private var configuredParameterSets: [Data] = []
    private var needsKeyframe = true

    public init(metrics: PipelineMetrics, output: @escaping VideoToolboxDecoder.FrameHandler) {
        self.metrics = metrics
        self.output = output
    }

    public var pendingFrames: Int { lock.withLock { decoder?.pendingFrames ?? 0 } }

    public func submit(
        _ packet: HEVCEncodedPacket,
        sequence: Int64,
        timestampUS: UInt64,
        fps: Double
    ) throws {
        try lock.withLock {
            if let status = decoder?.consumeAsyncDecodeError() {
                decoder?.invalidate()
                decoder = nil
                configuredParameterSets = []
                needsKeyframe = true
                metrics.recordDecoderReset(status: status)
                throw LiveHEVCDecoderError.asynchronousDecodeFailure(status)
            }
            for (type, value) in packet.parameterSets { parameterSets[type] = value }
            let ordered = [parameterSets[32], parameterSets[33], parameterSets[34]].compactMap { $0 }
            if ordered.count == 3, ordered != configuredParameterSets {
                decoder?.invalidate()
                decoder = try VideoToolboxDecoder(parameterSets: ordered, metrics: metrics, output: output)
                configuredParameterSets = ordered
                needsKeyframe = true
            }
            guard let decoder else { throw LiveHEVCDecoderError.waitingForParameterSets }
            if needsKeyframe {
                guard packet.isKeyframe else { throw LiveHEVCDecoderError.waitingForKeyframe }
                needsKeyframe = false
            }
            if decoder.pendingFrames >= Self.maximumPendingFrames {
                // RustDesk's low-delay HEVC stream may use every picture as a
                // reference until the next IDR. Drain the bounded decoder queue
                // instead of discarding an arbitrary reference picture.
                let started = DispatchTime.now().uptimeNanoseconds
                let waitStatus = decoder.waitForPendingFrames()
                metrics.recordBackpressureWait(
                    milliseconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                )
                if waitStatus != noErr {
                    decoder.invalidate()
                    self.decoder = nil
                    configuredParameterSets = []
                    needsKeyframe = true
                    metrics.recordDecoderReset(status: waitStatus)
                    throw LiveHEVCDecoderError.asynchronousDecodeFailure(waitStatus)
                }
                if let status = decoder.consumeAsyncDecodeError() {
                    decoder.invalidate()
                    self.decoder = nil
                    configuredParameterSets = []
                    needsKeyframe = true
                    metrics.recordDecoderReset(status: status)
                    throw LiveHEVCDecoderError.asynchronousDecodeFailure(status)
                }
                guard decoder.pendingFrames < Self.maximumPendingFrames else {
                    decoder.invalidate()
                    self.decoder = nil
                    configuredParameterSets = []
                    needsKeyframe = true
                    metrics.recordReferenceFrameDrop()
                    metrics.recordDecoderReset(status: nil)
                    throw LiveHEVCDecoderError.referenceFrameDropped
                }
            }
            do {
                try decoder.decode(
                    packet.accessUnit,
                    sequence: sequence,
                    fps: fps,
                    timestampUS: timestampUS
                )
            } catch {
                needsKeyframe = true
                throw error
            }
        }
    }

    public func invalidate() {
        lock.withLock {
            decoder?.invalidate()
            decoder = nil
            configuredParameterSets = []
            needsKeyframe = true
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
