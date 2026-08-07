import CoreMedia
import CoreVideo
import Foundation

public enum HostPipelineCodec: String, Equatable, Sendable {
  case h264
  case h265
}

public struct HostMediaAccessUnit: Sendable {
  public let codec: HostPipelineCodec
  public let data: Data
  public let presentationTimeUS: UInt64
  public let isKeyframe: Bool
  public let hasParameterSets: Bool
  public let logicalRawFrameCopyCount: Int
}

public struct HostMediaPipelineConfiguration: Sendable {
  public let codec: HostPipelineCodec
  public let displayIndex: Int
  public let width: Int
  public let height: Int
  public let framesPerSecond: Int
  public let bitRate: Int

  public init(
    codec: HostPipelineCodec = .h264,
    displayIndex: Int,
    width: Int,
    height: Int,
    framesPerSecond: Int,
    bitRate: Int
  ) {
    self.codec = codec
    self.displayIndex = displayIndex
    self.width = width
    self.height = height
    self.framesPerSecond = framesPerSecond
    self.bitRate = bitRate
  }
}

private enum HostMediaActiveEncoder {
  case h264(HostH264Encoder)
  case h265(HostHEVCEncoder)

  func requestKeyframe() {
    switch self {
    case .h264(let encoder): encoder.requestKeyframe()
    case .h265(let encoder): encoder.requestKeyframe()
    }
  }

  func encode(frame: HostCapturedFrame, presentationTime: CMTime) throws {
    switch self {
    case .h264(let encoder):
      try encoder.encode(
        pixelBuffer: frame.pixelBuffer,
        presentationTime: presentationTime,
        logicalRawFrameCopyCount: frame.logicalRawFrameCopyCount
      )
    case .h265(let encoder):
      try encoder.encode(
        pixelBuffer: frame.pixelBuffer,
        presentationTime: presentationTime,
        logicalRawFrameCopyCount: frame.logicalRawFrameCopyCount
      )
    }
  }

  func invalidate() {
    switch self {
    case .h264(let encoder): encoder.invalidate()
    case .h265(let encoder): encoder.invalidate()
    }
  }
}

/// H1 single-display SCK → VideoToolbox pipeline. The selected codec creates
/// exactly one process-local encoder; only compressed AVCC access units cross
/// the Host Media ABI.
public final class HostMediaPipeline: @unchecked Sendable {
  public typealias AccessUnitHandler = @Sendable (HostMediaAccessUnit) -> Void
  public typealias StateHandler = @Sendable (HostEncoderRuntimeState) -> Void
  public typealias ErrorHandler = @Sendable (Error) -> Void

  private let configuration: HostMediaPipelineConfiguration
  private let lock = NSLock()
  private let onAccessUnit: AccessUnitHandler
  private let onState: StateHandler
  private let onError: ErrorHandler
  private var capture: HostScreenCaptureAdapter?
  private var encoder: HostMediaActiveEncoder?
  private var firstPresentationTime: CMTime?
  private var active = false

  public init(
    configuration: HostMediaPipelineConfiguration,
    onAccessUnit: @escaping AccessUnitHandler,
    onState: @escaping StateHandler,
    onError: @escaping ErrorHandler
  ) {
    self.configuration = configuration
    self.onAccessUnit = onAccessUnit
    self.onState = onState
    self.onError = onError
  }

  public func start() async throws {
    let capture = HostScreenCaptureAdapter(
      onFrame: { [weak self] frame in self?.consume(frame) },
      onError: { [weak self] error in self?.onError(error) }
    )
    lock.withLock {
      active = true
      self.capture = capture
    }
    do {
      try await capture.start(
        configuration: HostCaptureConfiguration(
          displayIndex: configuration.displayIndex,
          width: configuration.width,
          height: configuration.height,
          framesPerSecond: configuration.framesPerSecond
        ))
    } catch {
      cancel()
      throw error
    }
  }

  public func requestKeyframe() {
    lock.withLock { encoder?.requestKeyframe() }
  }

  /// Synchronously prevents any further encoded submission. Stream shutdown
  /// remains async but is safe to finish after the Rust route is removed.
  public func cancel() {
    let encoder = lock.withLock { () -> HostMediaActiveEncoder? in
      active = false
      let value = self.encoder
      self.encoder = nil
      return value
    }
    encoder?.invalidate()
  }

  public func stop() async {
    cancel()
    let capture = lock.withLock { () -> HostScreenCaptureAdapter? in
      let value = self.capture
      self.capture = nil
      return value
    }
    await capture?.stop()
  }

  private func consume(_ frame: HostCapturedFrame) {
    let encoder: HostMediaActiveEncoder
    do {
      encoder = try lock.withLock {
        guard active else { throw HostScreenCaptureError.streamStopped("cancelled") }
        if let existing = self.encoder { return existing }
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let created = try self.makeEncoder(sourcePixelFormat: pixelFormat)
        self.encoder = created
        return created
      }
      let presentationTime = lock.withLock { () -> CMTime in
        if firstPresentationTime == nil { firstPresentationTime = frame.presentationTime }
        return CMTimeSubtract(frame.presentationTime, firstPresentationTime!)
      }
      try encoder.encode(frame: frame, presentationTime: presentationTime)
    } catch {
      onError(error)
    }
  }

  private func makeEncoder(sourcePixelFormat: OSType) throws -> HostMediaActiveEncoder {
    switch configuration.codec {
    case .h264:
      return .h264(
        try HostH264Encoder(
          configuration: HostH264EncoderConfiguration(
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            framesPerSecond: Int32(configuration.framesPerSecond),
            averageBitRate: configuration.bitRate
          ),
          sourcePixelFormat: sourcePixelFormat,
          onAccessUnit: { [weak self] accessUnit in
            self?.emit(
              codec: .h264,
              data: accessUnit.data,
              presentationTimeUS: accessUnit.presentationTimeUS,
              isKeyframe: accessUnit.isKeyframe,
              hasParameterSets: accessUnit.hasParameterSets,
              logicalRawFrameCopyCount: accessUnit.logicalRawFrameCopyCount
            )
          },
          onState: { [weak self] state in self?.emit(state: state) },
          onError: { [weak self] error in self?.onError(error) }
        ))
    case .h265:
      return .h265(
        try HostHEVCEncoder(
          configuration: HostHEVCEncoderConfiguration(
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            framesPerSecond: Int32(configuration.framesPerSecond),
            averageBitRate: configuration.bitRate
          ),
          sourcePixelFormat: sourcePixelFormat,
          onAccessUnit: { [weak self] accessUnit in
            self?.emit(
              codec: .h265,
              data: accessUnit.data,
              presentationTimeUS: accessUnit.presentationTimeUS,
              isKeyframe: accessUnit.isKeyframe,
              hasParameterSets: accessUnit.hasParameterSets,
              logicalRawFrameCopyCount: accessUnit.logicalRawFrameCopyCount
            )
          },
          onState: { [weak self] state in self?.emit(state: state) },
          onError: { [weak self] error in self?.onError(error) }
        ))
    }
  }

  private func emit(
    codec: HostPipelineCodec,
    data: Data,
    presentationTimeUS: UInt64,
    isKeyframe: Bool,
    hasParameterSets: Bool,
    logicalRawFrameCopyCount: Int
  ) {
    guard lock.withLock({ active }) else { return }
    onAccessUnit(
      HostMediaAccessUnit(
        codec: codec,
        data: data,
        presentationTimeUS: presentationTimeUS,
        isKeyframe: isKeyframe,
        hasParameterSets: hasParameterSets,
        logicalRawFrameCopyCount: logicalRawFrameCopyCount
      ))
  }

  private func emit(state: HostEncoderRuntimeState) {
    guard lock.withLock({ active }) else { return }
    onState(state)
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
