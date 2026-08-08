import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum HostCapturePixelPath: String, Sendable {
    /// ScreenCaptureKit supplied a bi-planar NV12 buffer that can be handed
    /// directly to VideoToolbox without a raw-frame copy.
    case biPlanarDirect
    /// ScreenCaptureKit supplied BGRA; VideoToolbox performs the single
    /// bounded pixel transfer. FarPane never performs a CPU full-frame loop.
    case bgraPixelTransfer

    public var logicalRawFrameCopyCount: Int {
        switch self {
        case .biPlanarDirect: 0
        case .bgraPixelTransfer: 1
        }
    }

    public static func classify(pixelFormat: OSType) -> HostCapturePixelPath? {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return .biPlanarDirect
        case kCVPixelFormatType_32BGRA:
            return .bgraPixelTransfer
        default:
            return nil
        }
    }
}

public struct HostCaptureConfiguration: Sendable {
    public let displayIndex: Int
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let showsCursor: Bool

    public init(
        displayIndex: Int,
        width: Int,
        height: Int,
        framesPerSecond: Int,
        showsCursor: Bool = true
    ) {
        self.displayIndex = displayIndex
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.showsCursor = showsCursor
    }

    public var isValid: Bool {
        displayIndex >= 0
            && (16...16_384).contains(width)
            && (16...16_384).contains(height)
            && (1...240).contains(framesPerSecond)
    }
}

public struct HostCapturedFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let pixelPath: HostCapturePixelPath
    public let dirtyRectCount: Int?
    public let dirtyAreaRatio: Double?

    public var logicalRawFrameCopyCount: Int {
        pixelPath.logicalRawFrameCopyCount
    }
}

public enum HostScreenCaptureError: Error, CustomStringConvertible {
    case invalidConfiguration
    case displayUnavailable
    case unsupportedPixelFormat(OSType)
    case configurationUpdateFailed(String)
    case streamStopped(String)

    public var description: String {
        switch self {
        case .invalidConfiguration: return "invalid host capture configuration"
        case .displayUnavailable: return "requested ScreenCaptureKit display is unavailable"
        case .unsupportedPixelFormat(let format):
            return "unsupported ScreenCaptureKit pixel format: \(format)"
        case .configurationUpdateFailed:
            return "ScreenCaptureKit configuration update failed"
        case .streamStopped: return "ScreenCaptureKit stream stopped"
        }
    }
}

enum HostCaptureFrameStatusDisposition: Equatable {
    case complete
    case idleFallback
    case ignore
}

enum HostCaptureFrameStatusKind: String, CaseIterable, Sendable {
    case complete
    case idle
    case blank
    case suspended
    case started
    case stopped
    case missingOrInvalid
    case unknown
}

enum HostCaptureDirtyRectsAttachmentState: String, CaseIterable, Sendable {
    case absent
    case unrecognized
    case recognizedEmpty
    case recognizedNonEmpty
}

struct HostCaptureSampleMetadataAvailability: Equatable, Sendable {
    let frameStatus: HostCaptureFrameStatusKind
    /// Present only when frameStatus is `.complete`.
    let completeFrameDirtyRects: HostCaptureDirtyRectsAttachmentState?
}

/// macOS 13-compatible single-display ScreenCaptureKit adapter (§11.1/§11.2).
/// It requests 420f first and classifies the actual delivered IOSurface on
/// every frame, so a system BGRA fallback remains explicit and measurable.
public final class HostScreenCaptureAdapter: NSObject, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (HostCapturedFrame) -> Void
    public typealias SampleHandler = @Sendable () -> Void
    typealias MetadataHandler = @Sendable (HostCaptureSampleMetadataAvailability) -> Void
    typealias DropHandler = @Sendable (HostMediaDropReason) -> Void
    public typealias ErrorHandler = @Sendable (HostScreenCaptureError) -> Void
    typealias CadenceHandler = @Sendable (HostCaptureCadenceEvent) -> Void
    typealias PressureProvider = @Sendable () -> HostCaptureBackpressure

    public static let preferredPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_32BGRA,
    ]

    private let captureQueue = DispatchQueue(
        label: "io.farpane.host-capture",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private let onFrame: FrameHandler
    private let onSample: MetadataHandler
    private let onDrop: DropHandler
    private let onCadence: CadenceHandler
    private let pressureProvider: PressureProvider
    private let onError: ErrorHandler
    private var stream: SCStream?
    private var captureConfiguration: HostCaptureConfiguration?
    private var cadenceController: HostCaptureCadenceController?
    private var appliedFramesPerSecond: Int?
    private var configurationUpdateInFlight = false
    private var nextConfigurationRetryNanoseconds: UInt64 = 0

    public convenience init(
        onFrame: @escaping FrameHandler,
        onSample: @escaping SampleHandler = {},
        onError: @escaping ErrorHandler
    ) {
        self.init(
            onFrame: onFrame,
            onSample: { _ in onSample() },
            onDrop: { _ in },
            onCadence: { _ in },
            pressureProvider: { .clear },
            onError: onError
        )
    }

    init(
        onFrame: @escaping FrameHandler,
        onSample: @escaping MetadataHandler,
        onDrop: @escaping DropHandler,
        onCadence: @escaping CadenceHandler,
        pressureProvider: @escaping PressureProvider,
        onError: @escaping ErrorHandler
    ) {
        self.onFrame = onFrame
        self.onSample = onSample
        self.onDrop = onDrop
        self.onCadence = onCadence
        self.pressureProvider = pressureProvider
        self.onError = onError
        super.init()
    }

    public func start(configuration: HostCaptureConfiguration) async throws {
        guard configuration.isValid else { throw HostScreenCaptureError.invalidConfiguration }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard content.displays.indices.contains(configuration.displayIndex) else {
            throw HostScreenCaptureError.displayUnavailable
        }
        let display = content.displays[configuration.displayIndex]
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let streamConfiguration = Self.streamConfiguration(
            for: configuration,
            framesPerSecond: configuration.framesPerSecond
        )
        let cadenceController = HostCaptureCadenceController(
            maximumFramesPerSecond: configuration.framesPerSecond
        )
        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        lock.withLock {
            self.stream = stream
            self.captureConfiguration = configuration
            self.cadenceController = cadenceController
            self.appliedFramesPerSecond = configuration.framesPerSecond
            self.configurationUpdateInFlight = false
            self.nextConfigurationRetryNanoseconds = 0
        }
        do {
            try await stream.startCapture()
        } catch {
            let cancelled = lock.withLock { () -> Bool in
                guard self.stream === stream else { return false }
                return clearStreamState()
            }
            if cancelled { onCadence(.configurationCancelled) }
            throw error
        }
    }

    static func streamConfiguration(
        for configuration: HostCaptureConfiguration,
        framesPerSecond: Int
    ) -> SCStreamConfiguration {
        let boundedFPS = min(
            configuration.framesPerSecond,
            max(1, framesPerSecond)
        )
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(boundedFPS)
        )
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.pixelFormat = Self.preferredPixelFormats[0]
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB
        return streamConfiguration
    }

    public func stop() async {
        let (stream, cancelled) = lock.withLock { () -> (SCStream?, Bool) in
            let value = self.stream
            return (value, clearStreamState())
        }
        if cancelled { onCadence(.configurationCancelled) }
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    private static func frameAttachments(
        from sampleBuffer: CMSampleBuffer
    ) -> [SCStreamFrameInfo: Any]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let first = attachments.first else { return nil }
        return first
    }

    private static func frameStatus(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> SCFrameStatus? {
        guard let raw = attachments?[.status] as? NSNumber else { return nil }
        return SCFrameStatus(rawValue: raw.intValue)
    }

    static func metadataAvailability(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> HostCaptureSampleMetadataAvailability {
        guard let raw = attachments?[.status] as? NSNumber else {
            return HostCaptureSampleMetadataAvailability(
                frameStatus: .missingOrInvalid,
                completeFrameDirtyRects: nil
            )
        }
        guard let status = SCFrameStatus(rawValue: raw.intValue) else {
            return HostCaptureSampleMetadataAvailability(
                frameStatus: .unknown,
                completeFrameDirtyRects: nil
            )
        }
        let statusKind: HostCaptureFrameStatusKind
        switch status {
        case .complete: statusKind = .complete
        case .idle: statusKind = .idle
        case .blank: statusKind = .blank
        case .suspended: statusKind = .suspended
        case .started: statusKind = .started
        case .stopped: statusKind = .stopped
        @unknown default: statusKind = .unknown
        }
        return HostCaptureSampleMetadataAvailability(
            frameStatus: statusKind,
            completeFrameDirtyRects: status == .complete
                ? dirtyRectsAttachmentState(from: attachments)
                : nil
        )
    }

    private static func dirtyRectsAttachmentState(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> HostCaptureDirtyRectsAttachmentState {
        guard let raw = attachments?[.dirtyRects] else { return .absent }
        guard let rects = raw as? [CGRect] else { return .unrecognized }
        return rects.isEmpty ? .recognizedEmpty : .recognizedNonEmpty
    }

    static func disposition(for frameStatus: SCFrameStatus) -> HostCaptureFrameStatusDisposition {
        switch frameStatus {
        case .complete: return .complete
        case .idle: return .idleFallback
        default: return .ignore
        }
    }

    private static func dirtyMetadata(
        from attachments: [SCStreamFrameInfo: Any]?,
        pixelBuffer: CVPixelBuffer
    ) -> (count: Int?, areaRatio: Double?) {
        guard let attachments else { return (nil, nil) }
        guard let rects = attachments[.dirtyRects] as? [CGRect] else { return (nil, nil) }
        let fallbackBounds = CGRect(
            x: 0,
            y: 0,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let bounds = (attachments[.contentRect] as? CGRect ?? fallbackBounds).standardized
        guard bounds.width > 0, bounds.height > 0 else { return (rects.count, nil) }
        let dirtyArea = rects.reduce(0.0) { partial, rect in
            let clipped = rect.standardized.intersection(bounds)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
                return partial
            }
            return partial + clipped.width * clipped.height
        }
        let ratio = min(1, max(0, dirtyArea / (bounds.width * bounds.height)))
        return (rects.count, ratio)
    }

    private func updateCadence(
        for stream: SCStream,
        observation: HostCaptureCadenceObservation
    ) {
        let now = DispatchTime.now().uptimeNanoseconds
        let backpressure = pressureProvider()
        var decisionToReport: HostCaptureCadenceDecision?
        let update = lock.withLock { () -> (HostCaptureConfiguration, Int)? in
            guard self.stream === stream,
                  let captureConfiguration,
                  var cadenceController else { return nil }
            let decision: HostCaptureCadenceDecision
            switch observation {
            case .completeFrame(let dirtyAreaRatio):
                decision = cadenceController.observe(
                    dirtyAreaRatio: dirtyAreaRatio,
                    backpressure: backpressure,
                    nowNanoseconds: now
                )
            case .idleFrameStatus:
                decision = cadenceController.observeIdleFrameStatus(
                    backpressure: backpressure,
                    nowNanoseconds: now
                )
            }
            self.cadenceController = cadenceController
            decisionToReport = decision
            guard decision.framesPerSecond != appliedFramesPerSecond,
                  !configurationUpdateInFlight,
                  now >= nextConfigurationRetryNanoseconds else { return nil }
            configurationUpdateInFlight = true
            return (captureConfiguration, decision.framesPerSecond)
        }
        if let decisionToReport { onCadence(.decision(decisionToReport)) }
        guard let (captureConfiguration, framesPerSecond) = update else { return }
        let streamConfiguration = Self.streamConfiguration(
            for: captureConfiguration,
            framesPerSecond: framesPerSecond
        )
        onCadence(.configurationSubmitted(framesPerSecond: framesPerSecond))
        stream.updateConfiguration(streamConfiguration) { [weak self, weak stream] error in
            guard let self, let stream else { return }
            var reportedError: HostScreenCaptureError?
            var cadenceEvent: HostCaptureCadenceEvent?
            self.lock.withLock {
                guard self.stream === stream else { return }
                self.configurationUpdateInFlight = false
                if let error {
                    self.nextConfigurationRetryNanoseconds =
                        DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                    reportedError = .configurationUpdateFailed(String(describing: error))
                    cadenceEvent = .configurationFailed(
                        framesPerSecond: framesPerSecond
                    )
                } else {
                    self.appliedFramesPerSecond = framesPerSecond
                    self.nextConfigurationRetryNanoseconds = 0
                    cadenceEvent = .configurationApplied(
                        framesPerSecond: framesPerSecond
                    )
                }
            }
            if let cadenceEvent { self.onCadence(cadenceEvent) }
            if let reportedError { self.onError(reportedError) }
        }
    }

    private func clearStreamState() -> Bool {
        let cancelledConfigurationUpdate = configurationUpdateInFlight
        stream = nil
        captureConfiguration = nil
        cadenceController = nil
        appliedFramesPerSecond = nil
        configurationUpdateInFlight = false
        nextConfigurationRetryNanoseconds = 0
        return cancelledConfigurationUpdate
    }
}

extension HostScreenCaptureAdapter: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        let attachments = Self.frameAttachments(from: sampleBuffer)
        onSample(Self.metadataAvailability(from: attachments))
        guard sampleBuffer.isValid else {
            onDrop(.invalidFrame)
            return
        }
        guard let status = Self.frameStatus(from: attachments) else {
            onDrop(.invalidFrame)
            return
        }
        switch Self.disposition(for: status) {
        case .idleFallback:
            updateCadence(for: stream, observation: .idleFrameStatus)
            return
        case .ignore:
            // blank/suspended/started/stopped are lifecycle state signals,
            // not hidden application drops and must not be mislabeled.
            return
        case .complete:
            break
        }
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            onDrop(.invalidFrame)
            return
        }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let pixelPath = HostCapturePixelPath.classify(pixelFormat: format) else {
            onDrop(.invalidFrame)
            onError(.unsupportedPixelFormat(format))
            return
        }
        let dirtyMetadata = Self.dirtyMetadata(
            from: attachments,
            pixelBuffer: pixelBuffer
        )
        onFrame(HostCapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: sampleBuffer.presentationTimeStamp,
            pixelPath: pixelPath,
            dirtyRectCount: dirtyMetadata.count,
            dirtyAreaRatio: dirtyMetadata.areaRatio
        ))
        updateCadence(
            for: stream,
            observation: .completeFrame(dirtyMetadata.areaRatio)
        )
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let (isCurrentStream, cancelled) = lock.withLock { () -> (Bool, Bool) in
            guard self.stream === stream else { return (false, false) }
            return (true, clearStreamState())
        }
        guard isCurrentStream else { return }
        if cancelled { onCadence(.configurationCancelled) }
        onError(.streamStopped(String(describing: error)))
    }
}

private enum HostCaptureCadenceObservation {
    case completeFrame(Double?)
    case idleFrameStatus
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
