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

public typealias HostHEVCEncoderConfiguration = HostVideoEncoderConfiguration
public typealias HostHEVCAccessUnit = HostVideoAccessUnit

public final class HostHEVCEncoder: HostVideoEncoder, @unchecked Sendable {
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
                codec: .hevc, configuration: configuration, sourcePixelFormat: sourcePixelFormat,
                onAccessUnit: onAccessUnit, onState: onState, onDrop: onDrop,
                onError: { onError(HostHEVCEncoderError($0)) })
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
