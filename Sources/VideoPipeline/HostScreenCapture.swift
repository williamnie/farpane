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

    public var logicalRawFrameCopyCount: Int {
        pixelPath.logicalRawFrameCopyCount
    }
}

public enum HostScreenCaptureError: Error, CustomStringConvertible {
    case invalidConfiguration
    case displayUnavailable
    case unsupportedPixelFormat(OSType)
    case streamStopped(String)

    public var description: String {
        switch self {
        case .invalidConfiguration: return "invalid host capture configuration"
        case .displayUnavailable: return "requested ScreenCaptureKit display is unavailable"
        case .unsupportedPixelFormat(let format):
            return "unsupported ScreenCaptureKit pixel format: \(format)"
        case .streamStopped: return "ScreenCaptureKit stream stopped"
        }
    }
}

/// macOS 13-compatible single-display ScreenCaptureKit adapter (§11.1/§11.2).
/// It requests 420f first and classifies the actual delivered IOSurface on
/// every frame, so a system BGRA fallback remains explicit and measurable.
public final class HostScreenCaptureAdapter: NSObject, @unchecked Sendable {
    public typealias FrameHandler = @Sendable (HostCapturedFrame) -> Void
    public typealias ErrorHandler = @Sendable (HostScreenCaptureError) -> Void

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
    private let onError: ErrorHandler
    private var stream: SCStream?

    public init(onFrame: @escaping FrameHandler, onError: @escaping ErrorHandler) {
        self.onFrame = onFrame
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
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.width
        streamConfiguration.height = configuration.height
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.framesPerSecond)
        )
        streamConfiguration.queueDepth = 3
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.pixelFormat = Self.preferredPixelFormats[0]
        streamConfiguration.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(
            filter: filter,
            configuration: streamConfiguration,
            delegate: self
        )
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        lock.withLock { self.stream = stream }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock { self.stream = nil }
            throw error
        }
    }

    public func stop() async {
        let stream = lock.withLock { () -> SCStream? in
            let value = self.stream
            self.stream = nil
            return value
        }
        guard let stream else { return }
        try? await stream.stopCapture()
    }

    private static func frameStatus(from sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let raw = attachments.first?[.status] as? NSNumber else { return nil }
        return SCFrameStatus(rawValue: raw.intValue)
    }

    private static func dirtyRectCount(from sampleBuffer: CMSampleBuffer) -> Int? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let first = attachments.first else { return nil }
        if let rects = first[.dirtyRects] as? [CGRect] { return rects.count }
        return nil
    }
}

extension HostScreenCaptureAdapter: SCStreamOutput, SCStreamDelegate {
    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              Self.frameStatus(from: sampleBuffer) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let pixelPath = HostCapturePixelPath.classify(pixelFormat: format) else {
            onError(.unsupportedPixelFormat(format))
            return
        }
        onFrame(HostCapturedFrame(
            pixelBuffer: pixelBuffer,
            presentationTime: sampleBuffer.presentationTimeStamp,
            pixelPath: pixelPath,
            dirtyRectCount: Self.dirtyRectCount(from: sampleBuffer)
        ))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { self.stream = nil }
        onError(.streamStopped(String(describing: error)))
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
