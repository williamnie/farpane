import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public struct HostH264EncoderConfiguration: Sendable {
    public let width: Int32
    public let height: Int32
    public let framesPerSecond: Int32
    public let averageBitRate: Int
    public let keyframeInterval: Int32
    public let requireHardware: Bool

    public init(
        width: Int32,
        height: Int32,
        framesPerSecond: Int32,
        averageBitRate: Int,
        keyframeInterval: Int32 = 120,
        requireHardware: Bool = true
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.averageBitRate = averageBitRate
        self.keyframeInterval = keyframeInterval
        self.requireHardware = requireHardware
    }

    public var isValid: Bool {
        (16...16_384).contains(width)
            && (16...16_384).contains(height)
            && (1...240).contains(framesPerSecond)
            && averageBitRate > 0
            && keyframeInterval > 0
    }
}

public struct HostH264AccessUnit: Sendable {
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

public enum HostH264EncoderError: Error, CustomStringConvertible {
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
        case .invalidConfiguration: return "invalid H.264 encoder configuration"
        case .create(let status): return "VTCompressionSessionCreate failed: \(status)"
        case .property(let key, let status): return "VideoToolbox property \(key) failed: \(status)"
        case .prepare(let status): return "VTCompressionSession prepare failed: \(status)"
        case .encode(let status): return "VideoToolbox encode submit failed: \(status)"
        case .callback(let status): return "VideoToolbox encode callback failed: \(status)"
        case .frameDropped: return "VideoToolbox dropped an H.264 frame"
        case .malformedSample: return "VideoToolbox returned a malformed H.264 sample"
        }
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

/// Real-time H.264 VideoToolbox encoder (§11.4). Hardware use is read back
/// only after the first successful callback; creation-time intent is never
/// reported as evidence that hardware was actually selected.
public final class HostH264Encoder: @unchecked Sendable {
    public typealias AccessUnitHandler = @Sendable (HostH264AccessUnit) -> Void
    public typealias StateHandler = @Sendable (HostEncoderRuntimeState) -> Void
    public typealias ErrorHandler = @Sendable (HostH264EncoderError) -> Void
    public typealias DropHandler = @Sendable (UInt64, HostMediaDropReason) -> Void

    public static var hardwareEncodingSupported: Bool {
        var session: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 16,
            height: 16,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }

    private let configuration: HostH264EncoderConfiguration
    private let lock = NSLock()
    private let stateQueue = DispatchQueue(label: "io.farpane.host-encoder-state")
    private let onAccessUnit: AccessUnitHandler
    private let onState: StateHandler
    private let onError: ErrorHandler
    private let onDrop: DropHandler
    private var session: VTCompressionSession?
    private var forceNextKeyframe = true
    private var reportedRuntimeState = false

    public init(
        configuration: HostH264EncoderConfiguration,
        sourcePixelFormat: OSType,
        onAccessUnit: @escaping AccessUnitHandler,
        onState: @escaping StateHandler,
        onDrop: @escaping DropHandler = { _, _ in },
        onError: @escaping ErrorHandler
    ) throws {
        guard configuration.isValid,
              HostCapturePixelPath.classify(pixelFormat: sourcePixelFormat) != nil else {
            throw HostH264EncoderError.invalidConfiguration
        }
        self.configuration = configuration
        self.onAccessUnit = onAccessUnit
        self.onState = onState
        self.onDrop = onDrop
        self.onError = onError

        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:
                configuration.requireHardware,
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
            allocator: kCFAllocatorDefault,
            width: configuration.width,
            height: configuration.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: sourceAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { throw HostH264EncoderError.create(status) }
        session = created
        do {
            try set(kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
            try set(kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            try set(
                kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_H264_Main_AutoLevel
            )
            try set(
                kVTCompressionPropertyKey_ExpectedFrameRate,
                value: configuration.framesPerSecond as CFNumber
            )
            try set(
                kVTCompressionPropertyKey_AverageBitRate,
                value: configuration.averageBitRate as CFNumber
            )
            let oneSecondBytes = max(1, configuration.averageBitRate / 8)
            try set(
                kVTCompressionPropertyKey_DataRateLimits,
                value: [oneSecondBytes, 1] as CFArray
            )
            try set(
                kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: configuration.keyframeInterval as CFNumber
            )
            let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
            guard prepared == noErr else { throw HostH264EncoderError.prepare(prepared) }
        } catch {
            VTCompressionSessionInvalidate(created)
            session = nil
            throw error
        }
    }

    deinit { invalidate() }

    public func requestKeyframe() {
        lock.withLock { forceNextKeyframe = true }
    }

    public func encode(frame: HostCapturedFrame) throws {
        try encode(
            pixelBuffer: frame.pixelBuffer,
            presentationTime: frame.presentationTime,
            logicalRawFrameCopyCount: frame.logicalRawFrameCopyCount
        )
    }

    public func encode(
        pixelBuffer: CVPixelBuffer,
        presentationTime: CMTime,
        logicalRawFrameCopyCount: Int,
        forceKeyframe: Bool = false
    ) throws {
        guard let session = lock.withLock({ self.session }) else {
            throw HostH264EncoderError.encode(kVTInvalidSessionErr)
        }
        let shouldForceKeyframe = lock.withLock { () -> Bool in
            let value = forceKeyframe || forceNextKeyframe
            forceNextKeyframe = false
            return value
        }
        let context = Unmanaged.passRetained(HostEncodeFrameContext(
            logicalRawFrameCopyCount: logicalRawFrameCopyCount,
            presentationTimeUS: UInt64(max(
                0,
                CMTimeConvertScale(
                    presentationTime,
                    timescale: 1_000_000,
                    method: .default
                ).value
            ))
        ))
        let frameProperties: CFDictionary? = shouldForceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            sourceFrameRefcon: context.toOpaque(),
            infoFlagsOut: nil
        )
        guard status == noErr else {
            context.release()
            lock.withLock { forceNextKeyframe = true }
            throw HostH264EncoderError.encode(status)
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
        guard let session else { throw HostH264EncoderError.property(key, kVTInvalidSessionErr) }
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else { throw HostH264EncoderError.property(key, status) }
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        refcon, frameRefcon, status, infoFlags, sampleBuffer in
        let frameContext = frameRefcon.map {
            Unmanaged<HostEncodeFrameContext>.fromOpaque($0).takeRetainedValue()
        }
        guard let refcon else { return }
        let encoder = Unmanaged<HostH264Encoder>.fromOpaque(refcon).takeUnretainedValue()
        guard status == noErr else {
            if let frameContext {
                encoder.onDrop(
                    frameContext.presentationTimeUS,
                    status == kVTVideoEncoderNotAvailableNowErr
                        ? .encoderBackpressure
                        : .invalidFrame
                )
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
            if let frameContext {
                encoder.onDrop(frameContext.presentationTimeUS, .invalidFrame)
            }
            encoder.onError(.malformedSample)
            return
        }
        do {
            try encoder.handle(
                sampleBuffer: sampleBuffer,
                logicalRawFrameCopyCount: frameContext.logicalRawFrameCopyCount
            )
        } catch let error as HostH264EncoderError {
            encoder.onDrop(frameContext.presentationTimeUS, .invalidFrame)
            encoder.onError(error)
        } catch {
            encoder.onDrop(frameContext.presentationTimeUS, .invalidFrame)
            encoder.onError(.malformedSample)
        }
    }

    private func handle(
        sampleBuffer: CMSampleBuffer,
        logicalRawFrameCopyCount: Int
    ) throws {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw HostH264EncoderError.malformedSample
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isKeyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] == nil
        var data = Data()
        var hasParameterSets = false
        if isKeyframe, let format = sampleBuffer.formatDescription {
            let parameterSets = try Self.h264ParameterSets(from: format)
            for parameterSet in parameterSets {
                var length = UInt32(parameterSet.count).bigEndian
                withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
                data.append(parameterSet)
            }
            hasParameterSets = !parameterSets.isEmpty
        }
        let payloadLength = CMBlockBufferGetDataLength(blockBuffer)
        guard payloadLength > 0 else { throw HostH264EncoderError.malformedSample }
        var payload = Data(count: payloadLength)
        let copied = payload.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: payloadLength,
                destination: bytes.baseAddress!
            )
        }
        guard copied == kCMBlockBufferNoErr else { throw HostH264EncoderError.malformedSample }
        data.append(payload)
        let pts = sampleBuffer.presentationTimeStamp
        let presentationTimeUS = UInt64(max(0, CMTimeConvertScale(
            pts,
            timescale: 1_000_000,
            method: .default
        ).value))

        scheduleRuntimeStateReportIfNeeded()
        onAccessUnit(HostH264AccessUnit(
            data: data,
            presentationTimeUS: presentationTimeUS,
            isKeyframe: isKeyframe,
            hasParameterSets: hasParameterSets,
            logicalRawFrameCopyCount: logicalRawFrameCopyCount
        ))
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
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(value)
            )
        }
        let hardware = hardwareStatus == noErr
            && (hardwareValue as? Bool == true)
        var encoderIDValue: CFTypeRef?
        let encoderIDStatus = withUnsafeMutablePointer(to: &encoderIDValue) { value in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_EncoderID,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(value)
            )
        }
        let encoderID = encoderIDStatus == noErr
            ? (encoderIDValue as? String ?? "unknown")
            : "unknown"
        onState(HostEncoderRuntimeState(
            hardwareAccelerated: hardware,
            softwareFallback: !hardware,
            encoderID: encoderID
        ))
    }

    private static func h264ParameterSets(
        from format: CMFormatDescription
    ) throws -> [Data] {
        var count = 0
        var headerLength: Int32 = 0
        let countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard countStatus == noErr, count > 0, headerLength == 4 else {
            throw HostH264EncoderError.malformedSample
        }
        return try (0..<count).map { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                throw HostH264EncoderError.malformedSample
            }
            return Data(bytes: pointer, count: size)
        }
    }
}
