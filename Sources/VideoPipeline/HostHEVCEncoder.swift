import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum HostHEVCEncoderError: Error, CustomStringConvertible {
    case invalidConfiguration
    case create(OSStatus)
    case property(CFString, OSStatus)
    case prepare(OSStatus)
    case encode(OSStatus)
    case callback(OSStatus)
    case frameDropped
    case malformedSample

    public var description: String {
        switch self {
        case .invalidConfiguration: return "invalid HEVC encoder configuration"
        case .create(let status): return "VTCompressionSessionCreate failed: \(status)"
        case .property(let key, let status): return "VideoToolbox property \(key) failed: \(status)"
        case .prepare(let status): return "VideoToolbox session prepare failed: \(status)"
        case .encode(let status): return "VideoToolbox encode submit failed: \(status)"
        case .callback(let status): return "VideoToolbox encode callback failed: \(status)"
        case .frameDropped: return "VideoToolbox dropped an HEVC frame"
        case .malformedSample: return "VideoToolbox returned a malformed HEVC sample"
        }
    }

    init(_ failure: HostVideoEncoderFailure) {
        switch failure {
        case .invalidConfiguration: self = .invalidConfiguration
        case .create(let status): self = .create(status)
        case .property(let key, let status): self = .property(key, status)
        case .prepare(let status): self = .prepare(status)
        case .encode(let status): self = .encode(status)
        case .callback(let status): self = .callback(status)
        case .frameDropped: self = .frameDropped
        case .malformedSample: self = .malformedSample
        }
    }
}

public struct HostHEVCEncoderConfiguration: Sendable {
    public let width: Int32
    public let height: Int32
    public let framesPerSecond: Int32
    public let averageBitRate: Int
    public let keyframeInterval: Int32
    public let requireHardware: Bool

    public init(
        width: Int32, height: Int32, framesPerSecond: Int32, averageBitRate: Int,
        keyframeInterval: Int32 = 120, requireHardware: Bool = true
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.averageBitRate = averageBitRate
        self.keyframeInterval = keyframeInterval
        self.requireHardware = requireHardware
    }

    public var isValid: Bool {
        (16...16_384).contains(width) && (16...16_384).contains(height)
            && (1...240).contains(framesPerSecond) && averageBitRate > 0 && keyframeInterval > 0
    }
}

public struct HostHEVCAccessUnit: Sendable {
    public let data: Data
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let logicalRawFrameCopyCount: Int
}

public final class HostHEVCEncoder: HostVideoEncoder, @unchecked Sendable {
    public typealias AccessUnitHandler = @Sendable (HostHEVCAccessUnit) -> Void
    public typealias ErrorHandler = @Sendable (HostHEVCEncoderError) -> Void

    public static var hardwareEncodingSupported: Bool {
        HostVideoEncoder.hardwareEncodingSupported(codec: .hevc)
    }

    public init(
        configuration: HostHEVCEncoderConfiguration, sourcePixelFormat: OSType,
        onAccessUnit: @escaping AccessUnitHandler, onState: @escaping StateHandler,
        onDrop: @escaping DropHandler = { _, _ in }, onError: @escaping ErrorHandler
    ) throws {
        do {
            try super.init(
                codec: .hevc,
                configuration: HostVideoEncoderConfiguration(
                    width: configuration.width, height: configuration.height,
                    framesPerSecond: configuration.framesPerSecond,
                    averageBitRate: configuration.averageBitRate,
                    keyframeInterval: configuration.keyframeInterval,
                    requireHardware: configuration.requireHardware),
                sourcePixelFormat: sourcePixelFormat,
                onAccessUnit: { unit in
                    onAccessUnit(
                        HostHEVCAccessUnit(
                            data: unit.data, presentationTimeUS: unit.presentationTimeUS,
                            isKeyframe: unit.isKeyframe, hasParameterSets: unit.hasParameterSets,
                            logicalRawFrameCopyCount: unit.logicalRawFrameCopyCount))
                }, onState: onState, onDrop: onDrop, onError: { onError(HostHEVCEncoderError($0)) })
        } catch let error as HostVideoEncoderFailure { throw HostHEVCEncoderError(error) }
    }

    public override func encode(
        pixelBuffer: CVPixelBuffer, presentationTime: CMTime, logicalRawFrameCopyCount: Int,
        forceKeyframe: Bool = false
    ) throws {
        do {
            try super.encode(
                pixelBuffer: pixelBuffer, presentationTime: presentationTime,
                logicalRawFrameCopyCount: logicalRawFrameCopyCount, forceKeyframe: forceKeyframe)
        } catch let error as HostVideoEncoderFailure { throw HostHEVCEncoderError(error) }
    }
}
