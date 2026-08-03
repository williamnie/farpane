import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

public enum VideoDecoderError: Error, CustomStringConvertible {
    case formatDescription(OSStatus)
    case session(OSStatus)
    case blockBuffer(OSStatus)
    case sampleBuffer(OSStatus)
    case decode(OSStatus)

    public var description: String {
        switch self {
        case .formatDescription(let s): return "CMVideoFormatDescriptionCreateFromHEVCParameterSets failed: \(s)"
        case .session(let s): return "VTDecompressionSessionCreate failed: \(s)"
        case .blockBuffer(let s): return "CMBlockBuffer creation failed: \(s)"
        case .sampleBuffer(let s): return "CMSampleBufferCreateReady failed: \(s)"
        case .decode(let s): return "VTDecompressionSessionDecodeFrame failed: \(s)"
        }
    }
}

public final class VideoToolboxDecoder: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (CVPixelBuffer, Double) -> Void

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private let output: FrameHandler
    private let stateLock = NSLock()
    private var submitTimes: [Int64: UInt64] = [:]
    private var _pendingFrames = 0
    private var asyncDecodeError: OSStatus?
    private let metrics: PipelineMetrics

    public var pendingFrames: Int { stateLock.withLock { _pendingFrames } }

    public func consumeAsyncDecodeError() -> OSStatus? {
        stateLock.withLock {
            defer { asyncDecodeError = nil }
            return asyncDecodeError
        }
    }

    public init(parameterSets: [Data], metrics: PipelineMetrics, output: @escaping FrameHandler) throws {
        self.output = output
        self.metrics = metrics
        try configure(parameterSets: parameterSets)
    }

    deinit { invalidate() }

    public func decode(
        _ accessUnit: HEVCAccessUnit,
        sequence: Int64,
        fps: Double,
        timestampUS: UInt64? = nil
    ) throws {
        guard let session, let formatDescription else { throw VideoDecoderError.session(-1) }
        let payload = accessUnit.avccData
        var blockBuffer: CMBlockBuffer?
        let blockStatus = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: payload.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: payload.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ).flatMapSuccess {
                CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: payload.count)
            }
        }
        guard blockStatus == noErr, let blockBuffer else { throw VideoDecoderError.blockBuffer(blockStatus) }

        let timescale = CMTimeScale(max(1, fps.rounded()))
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: timestampUS.map {
                CMTime(value: CMTimeValue($0), timescale: 1_000_000)
            } ?? CMTime(value: sequence, timescale: timescale),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = payload.count
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { throw VideoDecoderError.sampleBuffer(sampleStatus) }

        stateLock.withLock {
            submitTimes[sequence] = DispatchTime.now().uptimeNanoseconds
            _pendingFrames += 1
            metrics.recordSubmitted(queueDepth: _pendingFrames)
        }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil,
            outputHandler: { [weak self] status, _, imageBuffer, _, _ in
                self?.didDecode(status: status, imageBuffer: imageBuffer, sequence: sequence)
            }
        )
        if status != noErr {
            stateLock.withLock { submitTimes.removeValue(forKey: sequence); _pendingFrames = max(0, _pendingFrames - 1) }
            throw VideoDecoderError.decode(status)
        }
    }

    public func finishDelayedFrames() {
        if let session { VTDecompressionSessionFinishDelayedFrames(session) }
    }

    public func waitForPendingFrames() -> OSStatus {
        guard let session else { return kVTInvalidSessionErr }
        return VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    public func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDescription = nil
    }

    private func configure(parameterSets: [Data]) throws {
        let status: OSStatus = parameterSets.withUnsafeParameterSetPointers { pointers, sizes in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: parameterSets.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }
        guard status == noErr, let formatDescription else { throw VideoDecoderError.formatDescription(status) }

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: nil,
            decompressionOutputRefCon: nil
        )
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )
        guard sessionStatus == noErr, let session else { throw VideoDecoderError.session(sessionStatus) }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        var hardwareValue: Unmanaged<CFTypeRef>?
        let hardwareStatus = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &hardwareValue
        )
        let hardwareObject = hardwareValue?.takeRetainedValue()
        metrics.recordHardwareDecode(active: hardwareStatus == noErr && (hardwareObject as? Bool) == true)
    }

    private func didDecode(status: OSStatus, imageBuffer: CVImageBuffer?, sequence: Int64) {
        let started: UInt64? = stateLock.withLock {
            _pendingFrames = max(0, _pendingFrames - 1)
            return submitTimes.removeValue(forKey: sequence)
        }
        guard status == noErr, let pixelBuffer = imageBuffer else {
            stateLock.withLock { asyncDecodeError = status }
            metrics.recordDecodeError(status: status)
            return
        }
        let elapsed = started.map { Double(DispatchTime.now().uptimeNanoseconds - $0) / 1_000_000 } ?? 0
        metrics.recordDecodedDimensions(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        metrics.recordDecoded(milliseconds: elapsed)
        output(pixelBuffer, elapsed)
    }
}

private extension OSStatus {
    func flatMapSuccess(_ body: () -> OSStatus) -> OSStatus { self == noErr ? body() : self }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

private extension [Data] {
    func withUnsafeParameterSetPointers<R>(
        _ body: ([UnsafePointer<UInt8>], [Int]) -> R
    ) -> R {
        func recurse(_ index: Int, _ pointers: [UnsafePointer<UInt8>], _ sizes: [Int]) -> R {
            if index == count { return body(pointers, sizes) }
            return self[index].withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    preconditionFailure("HEVC parameter set must not be empty")
                }
                return recurse(index + 1, pointers + [base], sizes + [self[index].count])
            }
        }
        return recurse(0, [], [])
    }
}
