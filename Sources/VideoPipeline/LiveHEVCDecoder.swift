import Foundation

public enum LiveHEVCDecoderError: Error, CustomStringConvertible {
    case waitingForParameterSets
    case waitingForKeyframe
    case referenceFrameDropped
    case asynchronousDecodeFailure(OSStatus)

    public var description: String {
        switch self {
        case .waitingForParameterSets: return "waiting for video parameter sets"
        case .waitingForKeyframe: return "waiting for video keyframe after decoder reset"
        case .referenceFrameDropped:
            return "live video reference frame dropped under decoder backpressure"
        case .asynchronousDecodeFailure(let status):
            return "VideoToolbox asynchronous decode failed: \(status)"
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
    private var codec: HostPipelineCodec?

    public init(metrics: PipelineMetrics, output: @escaping VideoToolboxDecoder.FrameHandler) {
        self.metrics = metrics
        self.output = output
    }

    public var pendingFrames: Int { lock.withLock { decoder?.pendingFrames ?? 0 } }

    public func submit(
        _ packet: HEVCEncodedPacket, sequence: Int64, timestampUS: UInt64, fps: Double
    ) throws {
        try submit(
            parameterSets: packet.parameterSets, accessUnit: packet.accessUnit, codec: .h265,
            sequence: sequence, timestampUS: timestampUS, fps: fps)
    }

    public func submit(
        _ packet: H264FramingAccessUnit, sequence: Int64, timestampUS: UInt64, fps: Double
    ) throws {
        var sets: [UInt8: Data] = [:]
        for unit in packet.nalUnits where unit.type == 7 || unit.type == 8 {
            sets[unit.type] = unit.data
        }
        try submit(
            parameterSets: sets,
            accessUnit: HEVCAccessUnit(
                nalUnits: packet.nalUnits.map(\.data), isKeyframe: packet.isIDR), codec: .h264,
            sequence: sequence, timestampUS: timestampUS, fps: fps)
    }

    private func submit(
        parameterSets incomingSets: [UInt8: Data], accessUnit: HEVCAccessUnit,
        codec: HostPipelineCodec, sequence: Int64, timestampUS: UInt64, fps: Double
    ) throws {
        try lock.withLock {
            if self.codec != codec {
                decoder?.invalidate()
                decoder = nil
                parameterSets = [:]
                configuredParameterSets = []
                needsKeyframe = true
                self.codec = codec
            }
            if let status = decoder?.consumeAsyncDecodeError() {
                decoder?.invalidate()
                decoder = nil
                configuredParameterSets = []
                needsKeyframe = true
                metrics.recordDecoderReset(status: status)
                throw LiveHEVCDecoderError.asynchronousDecodeFailure(status)
            }
            for (type, value) in incomingSets { parameterSets[type] = value }
            let requiredTypes: [UInt8] = codec == .h264 ? [7, 8] : [32, 33, 34]
            let ordered = requiredTypes.compactMap { parameterSets[$0] }
            if ordered.count == requiredTypes.count, ordered != configuredParameterSets {
                decoder?.invalidate()
                decoder = try VideoToolboxDecoder(
                    parameterSets: ordered, codec: codec, metrics: metrics, output: output)
                configuredParameterSets = ordered
                needsKeyframe = true
            }
            guard let decoder else { throw LiveHEVCDecoderError.waitingForParameterSets }
            if needsKeyframe {
                guard accessUnit.isKeyframe else { throw LiveHEVCDecoderError.waitingForKeyframe }
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
                    accessUnit, sequence: sequence, fps: fps, timestampUS: timestampUS)
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

extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
