import CoreMedia
import CoreVideo
import Foundation

public struct HostHardwareEncoderProbeConfiguration: Sendable {
  public let codec: HostPipelineCodec
  public let width: Int
  public let height: Int
  public let framesPerSecond: Int
  public let sourcePixelFormat: OSType

  public init(
    codec: HostPipelineCodec,
    width: Int,
    height: Int,
    framesPerSecond: Int,
    sourcePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
  ) {
    self.codec = codec
    self.width = width
    self.height = height
    self.framesPerSecond = framesPerSecond
    self.sourcePixelFormat = sourcePixelFormat
  }

  fileprivate var isValid: Bool {
    (16...16_384).contains(width)
      && (16...16_384).contains(height)
      && width * height <= 7_680 * 4_320
      && (1...240).contains(framesPerSecond)
      && HostCapturePixelPath.classify(pixelFormat: sourcePixelFormat) != nil
  }
}

public enum HostHardwareEncoderProbeFailure: String, Sendable {
  case invalidConfiguration
  case pixelBufferAllocation
  case encoderCreation
  case encodeSubmission
  case callbackFailure
  case timedOut
  case softwareFallback
}

public struct HostHardwareEncoderProbeResult: Sendable {
  public let configuration: HostHardwareEncoderProbeConfiguration
  public let hardwareAccelerated: Bool
  public let encoderID: String?
  public let producedKeyframeWithParameterSets: Bool
  public let failure: HostHardwareEncoderProbeFailure?

  public var isAvailable: Bool {
    failure == nil
      && hardwareAccelerated
      && producedKeyframeWithParameterSets
      && !(encoderID?.isEmpty ?? true)
  }
}

/// Performs a real first-frame encode for the exact codec, source format and
/// dimensions before that capability is advertised. Work runs off the caller
/// executor because VideoToolbox callback readback may take several seconds.
public enum HostHardwareEncoderProbe {
  private static let queue = DispatchQueue(
    label: "io.farpane.host-hardware-encoder-probe",
    qos: .userInitiated
  )
  private static let timeout: TimeInterval = 5

  public static func probe(
    configuration: HostHardwareEncoderProbeConfiguration
  ) async -> HostHardwareEncoderProbeResult {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: run(configuration: configuration))
      }
    }
  }

  private static func run(
    configuration: HostHardwareEncoderProbeConfiguration
  ) -> HostHardwareEncoderProbeResult {
    guard configuration.isValid else {
      return failure(.invalidConfiguration, configuration: configuration)
    }
    guard let pixelBuffer = makePixelBuffer(configuration: configuration) else {
      return failure(.pixelBufferAllocation, configuration: configuration)
    }
    let observation = HostHardwareEncoderProbeObservation()
    let bitRate = max(
      500_000,
      min(40_000_000, configuration.width * configuration.height
        * configuration.framesPerSecond / 10)
    )
    var invalidateEncoder: (() -> Void)?
    defer { invalidateEncoder?() }

    switch configuration.codec {
    case .h264:
      let encoder: HostH264Encoder
      do {
        encoder = try HostH264Encoder(
          configuration: HostH264EncoderConfiguration(
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            framesPerSecond: Int32(configuration.framesPerSecond),
            averageBitRate: bitRate
          ),
          sourcePixelFormat: configuration.sourcePixelFormat,
          onAccessUnit: { accessUnit in
            observation.recordAccessUnit(
              isKeyframe: accessUnit.isKeyframe,
              hasParameterSets: accessUnit.hasParameterSets,
              isEmpty: accessUnit.data.isEmpty
            )
          },
          onState: { observation.record(state: $0) },
          onDrop: { _, _ in observation.record(failure: .callbackFailure) },
          onError: { _ in observation.record(failure: .callbackFailure) }
        )
      } catch {
        return failure(.encoderCreation, configuration: configuration)
      }
      invalidateEncoder = { encoder.invalidate() }
      do {
        try encoder.encode(
          pixelBuffer: pixelBuffer,
          presentationTime: CMTime(value: 1, timescale: 1_000_000),
          logicalRawFrameCopyCount: 0,
          forceKeyframe: true
        )
      } catch {
        return failure(.encodeSubmission, configuration: configuration)
      }

    case .h265:
      let encoder: HostHEVCEncoder
      do {
        encoder = try HostHEVCEncoder(
          configuration: HostHEVCEncoderConfiguration(
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            framesPerSecond: Int32(configuration.framesPerSecond),
            averageBitRate: bitRate
          ),
          sourcePixelFormat: configuration.sourcePixelFormat,
          onAccessUnit: { accessUnit in
            observation.recordAccessUnit(
              isKeyframe: accessUnit.isKeyframe,
              hasParameterSets: accessUnit.hasParameterSets,
              isEmpty: accessUnit.data.isEmpty
            )
          },
          onState: { observation.record(state: $0) },
          onDrop: { _, _ in observation.record(failure: .callbackFailure) },
          onError: { _ in observation.record(failure: .callbackFailure) }
        )
      } catch {
        return failure(.encoderCreation, configuration: configuration)
      }
      invalidateEncoder = { encoder.invalidate() }
      do {
        try encoder.encode(
          pixelBuffer: pixelBuffer,
          presentationTime: CMTime(value: 1, timescale: 1_000_000),
          logicalRawFrameCopyCount: 0,
          forceKeyframe: true
        )
      } catch {
        return failure(.encodeSubmission, configuration: configuration)
      }
    }

    guard let snapshot = observation.wait(timeout: timeout) else {
      return failure(.timedOut, configuration: configuration)
    }
    if let callbackFailure = snapshot.failure {
      return failure(callbackFailure, configuration: configuration)
    }
    guard let state = snapshot.state, state.hardwareAccelerated else {
      return failure(.softwareFallback, configuration: configuration)
    }
    return HostHardwareEncoderProbeResult(
      configuration: configuration,
      hardwareAccelerated: true,
      encoderID: state.encoderID,
      producedKeyframeWithParameterSets: snapshot.producedKeyframeWithParameterSets,
      failure: snapshot.producedKeyframeWithParameterSets ? nil : .callbackFailure
    )
  }

  private static func makePixelBuffer(
    configuration: HostHardwareEncoderProbeConfiguration
  ) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      configuration.width,
      configuration.height,
      configuration.sourcePixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &buffer
    )
    guard status == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if CVPixelBufferIsPlanar(buffer) {
      for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
        guard let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
        memset(
          address,
          plane == 0 ? 16 : 128,
          CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            * CVPixelBufferGetHeightOfPlane(buffer, plane)
        )
      }
    } else if let address = CVPixelBufferGetBaseAddress(buffer) {
      memset(address, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
    return buffer
  }

  private static func failure(
    _ failure: HostHardwareEncoderProbeFailure,
    configuration: HostHardwareEncoderProbeConfiguration
  ) -> HostHardwareEncoderProbeResult {
    HostHardwareEncoderProbeResult(
      configuration: configuration,
      hardwareAccelerated: false,
      encoderID: nil,
      producedKeyframeWithParameterSets: false,
      failure: failure
    )
  }
}

private struct HostHardwareEncoderProbeSnapshot {
  let state: HostEncoderRuntimeState?
  let producedKeyframeWithParameterSets: Bool
  let failure: HostHardwareEncoderProbeFailure?
}

private final class HostHardwareEncoderProbeObservation: @unchecked Sendable {
  private let condition = NSCondition()
  private var state: HostEncoderRuntimeState?
  private var producedKeyframeWithParameterSets = false
  private var failure: HostHardwareEncoderProbeFailure?

  func record(state: HostEncoderRuntimeState) {
    condition.lock()
    self.state = state
    condition.broadcast()
    condition.unlock()
  }

  func recordAccessUnit(isKeyframe: Bool, hasParameterSets: Bool, isEmpty: Bool) {
    condition.lock()
    producedKeyframeWithParameterSets = isKeyframe && hasParameterSets && !isEmpty
    condition.broadcast()
    condition.unlock()
  }

  func record(failure: HostHardwareEncoderProbeFailure) {
    condition.lock()
    if self.failure == nil { self.failure = failure }
    condition.broadcast()
    condition.unlock()
  }

  func wait(timeout: TimeInterval) -> HostHardwareEncoderProbeSnapshot? {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while failure == nil && (state == nil || !producedKeyframeWithParameterSets) {
      guard condition.wait(until: deadline) else { return nil }
    }
    return HostHardwareEncoderProbeSnapshot(
      state: state,
      producedKeyframeWithParameterSets: producedKeyframeWithParameterSets,
      failure: failure
    )
  }
}
