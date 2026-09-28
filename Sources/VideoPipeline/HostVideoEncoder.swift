import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct HostVideoEncoderConfiguration: Sendable {
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

public struct HostVideoAccessUnit: Sendable {
    public let data: Data
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let logicalRawFrameCopyCount: Int
}

public struct HostEncoderRuntimeState: Equatable, Sendable {
    public let hardwareAccelerated: Bool
    public let softwareFallback: Bool
    public let encoderID: String
}

enum HostVideoEncoderFailure: Error {
    case invalidConfiguration
    case create(OSStatus)
    case property(CFString, OSStatus)
    case prepare(OSStatus)
    case encode(OSStatus)
    case callback(OSStatus)
    case frameDropped
    case malformedSample
}

enum HostCompressionCodec {
    case h264, hevc
    var type: CMVideoCodecType { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }
    var profile: CFString {
        self == .h264 ? kVTProfileLevel_H264_Main_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
    }
    var minimumParameterSets: Int { self == .h264 ? 1 : 3 }
    var queueLabel: String {
        self == .h264 ? "io.farpane.host-encoder-state" : "io.farpane.host-hevc-encoder-state"
    }
}

private final class HostEncodeFrameContext {
    let logicalRawFrameCopyCount: Int
    let presentationTimeUS: UInt64

    init(logicalRawFrameCopyCount: Int, presentationTimeUS: UInt64) {
        self.logicalRawFrameCopyCount = logicalRawFrameCopyCount
        self.presentationTimeUS = presentationTimeUS
    }
}

/// Shared VideoToolbox encoder. Hardware use is read back
/// only after the first successful callback; creation-time intent is never
/// reported as evidence that hardware was actually selected.
public class HostVideoEncoder: @unchecked Sendable {
    public typealias AccessUnitHandler = @Sendable (HostVideoAccessUnit) -> Void
    public typealias StateHandler = @Sendable (HostEncoderRuntimeState) -> Void
    typealias ErrorHandler = @Sendable (HostVideoEncoderFailure) -> Void
    public typealias DropHandler = @Sendable (UInt64, HostMediaDropReason) -> Void

    static func hardwareEncodingSupported(codec: HostCompressionCodec) -> Bool {
        var session: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: 16, height: 16, codecType: codec.type,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    private let configuration: HostVideoEncoderConfiguration
    private let lock = NSLock()
    private let stateQueue: DispatchQueue
    private let codec: HostCompressionCodec
    private let onAccessUnit: AccessUnitHandler
    private let onState: StateHandler
    private let onError: ErrorHandler
    private let onDrop: DropHandler
    private var session: VTCompressionSession?
    private var forceNextKeyframe = true
    private var reportedRuntimeState = false

    init(
        codec: HostCompressionCodec, configuration: HostVideoEncoderConfiguration,
        sourcePixelFormat: OSType, onAccessUnit: @escaping AccessUnitHandler,
        onState: @escaping StateHandler, onDrop: @escaping DropHandler = { _, _ in },
        onError: @escaping ErrorHandler
    ) throws {
        self.codec = codec
        stateQueue = DispatchQueue(label: codec.queueLabel)
        guard configuration.isValid,
            HostCapturePixelPath.classify(pixelFormat: sourcePixelFormat) != nil
        else { throw HostVideoEncoderFailure.invalidConfiguration }
        self.configuration = configuration
        self.onAccessUnit = onAccessUnit
        self.onState = onState
        self.onDrop = onDrop
        self.onError = onError

        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: configuration
                .requireHardware,
        ]
        let sourceAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: sourcePixelFormat,
            kCVPixelBufferWidthKey: configuration.width,
            kCVPixelBufferHeightKey: configuration.height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: configuration.width,
            height: configuration.height, codecType: codec.type,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: Self.outputCallback, refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created)
        guard status == noErr, let created else { throw HostVideoEncoderFailure.create(status) }
        session = created
        do {
            try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try set(kVTCompressionPropertyKey_ProfileLevel, value: codec.profile)
            try set(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: configuration.framesPerSecond as CFNumber)
            try set(
                kVTCompressionPropertyKey_AverageBitRate,
                value: configuration.averageBitRate as CFNumber)
            let oneSecondBytes = max(1, configuration.averageBitRate / 8)
            try set(
                kVTCompressionPropertyKey_DataRateLimits, value: [oneSecondBytes, 1] as CFArray)
            try set(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: configuration.keyframeInterval as CFNumber)
            let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepared == noErr else { throw HostVideoEncoderFailure.prepare(prepared) }
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    deinit { invalidate() }

    public func requestKeyframe() { lock.withLock { forceNextKeyframe = true } }

    public func encode(frame: HostCapturedFrame) throws {
        try encode(
            pixelBuffer: frame.pixelBuffer, presentationTime: frame.presentationTime,
            logicalRawFrameCopyCount: frame.logicalRawFrameCopyCount)
    }

    public func encode(
        pixelBuffer: CVPixelBuffer, presentationTime: CMTime, logicalRawFrameCopyCount: Int,
        forceKeyframe: Bool = false
    ) throws {
        guard let session = lock.withLock({ self.session }) else {
            throw HostVideoEncoderFailure.encode(kVTInvalidSessionErr)
        }
        let shouldForceKeyframe = lock.withLock { () -> Bool in
            let value = forceKeyframe || forceNextKeyframe
            forceNextKeyframe = false
            return value
        }
        let context = Unmanaged.passRetained(
            HostEncodeFrameContext(
                logicalRawFrameCopyCount: logicalRawFrameCopyCount,
                presentationTimeUS: UInt64(
                    max(
                        0,
                        CMTimeConvertScale(presentationTime, timescale: 1_000_000, method: .default)
                            .value))))
        let frameProperties: CFDictionary? =
            shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: frameProperties,
            sourceFrameRefcon: context.toOpaque(), infoFlagsOut: nil)
        guard status == noErr else {
            context.release()
            lock.withLock { forceNextKeyframe = true }
            throw HostVideoEncoderFailure.encode(status)
        }
        // Once VideoToolbox accepts the frame, its output callback owns the
        // retained context. A synchronous frame drop may invoke that callback
        // before this function returns, so reading infoFlagsOut and releasing
        // the same context here would double-release it. The callback's
        // infoFlags is the single authority for completion and drop handling.
    }

    public func invalidate() {
        let session = lock.withLock { () -> VTCompressionSession? in
            let value = self.session
            self.session = nil
            return value
        }
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func set(_ key: CFString, value: CFTypeRef) throws {
        guard let session else { throw HostVideoEncoderFailure.property(key, kVTInvalidSessionErr) }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw HostVideoEncoderFailure.property(key, status) }
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        refcon, frameRefcon, status, infoFlags, sampleBuffer in
        let frameContext = frameRefcon.map {
            Unmanaged<HostEncodeFrameContext>.fromOpaque($0).takeRetainedValue()
        }
        guard let refcon else { return }
        let encoder = Unmanaged<HostVideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr else {
            if let frameContext {
                encoder.onDrop(
                    frameContext.presentationTimeUS,
                    status == kVTVideoEncoderNotAvailableNowErr
                        ? .encoderBackpressure : .invalidFrame)
            }
            encoder.onError(.callback(status))
            return
        }
        guard !infoFlags.contains(.frameDropped) else {
            if let frameContext {
                encoder.onDrop(frameContext.presentationTimeUS, .encoderBackpressure)
            }
            encoder.requestKeyframe()
            encoder.onError(.frameDropped)
            return
        }
        guard let sampleBuffer, let frameContext else {
            if let frameContext { encoder.onDrop(frameContext.presentationTimeUS, .invalidFrame) }
            encoder.onError(.malformedSample)
            return
        }
        do {
            try encoder.handle(
                sampleBuffer: sampleBuffer,
                logicalRawFrameCopyCount: frameContext.logicalRawFrameCopyCount)
        } catch let error as HostVideoEncoderFailure {
            encoder.onDrop(frameContext.presentationTimeUS, .invalidFrame)
            encoder.onError(error)
        } catch {
            encoder.onDrop(frameContext.presentationTimeUS, .invalidFrame)
            encoder.onError(.malformedSample)
        }
    }

    private func handle(sampleBuffer: CMSampleBuffer, logicalRawFrameCopyCount: Int) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
        else { throw HostVideoEncoderFailure.malformedSample }
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        var data = Data()
        var hasParameterSets = false
        if isKeyframe, let format = sampleBuffer.formatDescription {
            let parameterSets = try parameterSets(from: format)
            for parameterSet in parameterSets {
                var length = UInt32(parameterSet.count).bigEndian
                withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
                data.append(parameterSet)
            }
            hasParameterSets = parameterSets.count >= codec.minimumParameterSets
        }
        let payloadLength = CMBlockBufferGetDataLength(blockBuffer)
        guard payloadLength > 0 else { throw HostVideoEncoderFailure.malformedSample }
        var payload = Data(count: payloadLength)
        let copied = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer, atOffset: 0, dataLength: payloadLength, destination: bytes.baseAddress!
            )
        }
        guard copied == kCMBlockBufferNoErr else { throw HostVideoEncoderFailure.malformedSample }
        data.append(payload)
        let pts = sampleBuffer.presentationTimeStamp
        let presentationTimeUS = UInt64(
            max(0, CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value))

        scheduleRuntimeStateReportIfNeeded()
        onAccessUnit(
            HostVideoAccessUnit(
                data: data, presentationTimeUS: presentationTimeUS, isKeyframe: isKeyframe,
                hasParameterSets: hasParameterSets,
                logicalRawFrameCopyCount: logicalRawFrameCopyCount))
    }

    private func scheduleRuntimeStateReportIfNeeded() {
        let shouldSchedule = lock.withLock { () -> Bool in
            guard !reportedRuntimeState else { return false }
            reportedRuntimeState = true
            return true
        }
        guard shouldSchedule else { return }
        stateQueue.async { [weak self] in self?.reportRuntimeState() }
    }

    private func reportRuntimeState() {
        guard let session = lock.withLock({ self.session }) else { return }
        var hardwareValue: CFTypeRef?
        let hardwareStatus = withUnsafeMutablePointer(to: &hardwareValue) { value in
            VTSessionCopyProperty(
                session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault, valueOut: UnsafeMutableRawPointer(value))
        }
        let hardware = hardwareStatus == noErr && (hardwareValue as? Bool == true)
        var encoderIDValue: CFTypeRef?
        let encoderIDStatus = withUnsafeMutablePointer(to: &encoderIDValue) { value in
            VTSessionCopyProperty(
                session, key: kVTCompressionPropertyKey_EncoderID, allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(value))
        }
        let encoderID =
            encoderIDStatus == noErr ? (encoderIDValue as? String ?? "unknown") : "unknown"
        onState(
            HostEncoderRuntimeState(
                hardwareAccelerated: hardware, softwareFallback: !hardware, encoderID: encoderID))
    }

    private func parameterSets(from format: CMFormatDescription) throws -> [Data] {
        let getParameterSet =
            codec == .h264
            ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
        var count = 0
        var headerLength: Int32 = 0
        let countStatus = getParameterSet(format, 0, nil, nil, &count, &headerLength)
        guard countStatus == noErr, count >= codec.minimumParameterSets, headerLength == 4 else {
            throw HostVideoEncoderFailure.malformedSample
        }
        return try (0..<count).map { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = getParameterSet(format, index, &pointer, &size, nil, nil)
            guard status == noErr, let pointer, size > 0 else {
                throw HostVideoEncoderFailure.malformedSample
            }
            return Data(bytes: pointer, count: size)
        }
    }
}
