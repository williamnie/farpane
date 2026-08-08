import CoreVideo
import Foundation

public struct HostHardwareEncoderCapabilityTarget: Sendable, Equatable {
  public let width: Int
  public let height: Int
  public let maximumFramesPerSecond: Int
  public let sourcePixelFormat: OSType

  public init?(
    width: Int,
    height: Int,
    maximumFramesPerSecond: Int,
    sourcePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
  ) {
    guard (16...16_384).contains(width),
      (16...16_384).contains(height),
      width * height <= 7_680 * 4_320,
      (1...240).contains(maximumFramesPerSecond),
      HostCapturePixelPath.classify(pixelFormat: sourcePixelFormat) != nil
    else { return nil }
    self.width = width
    self.height = height
    self.maximumFramesPerSecond = maximumFramesPerSecond
    self.sourcePixelFormat = sourcePixelFormat
  }

  fileprivate var frameRateCandidates: [Int] {
    [maximumFramesPerSecond, min(30, maximumFramesPerSecond), min(15, maximumFramesPerSecond)]
      .reduce(into: []) { candidates, value in
        if !candidates.contains(value) { candidates.append(value) }
      }
  }
}

public struct HostDiscoveredEncoderCapabilities: Sendable, Equatable {
  public let h264Hardware: Bool
  public let h265Hardware: Bool
  public let maxWidth: Int
  public let maxHeight: Int
  public let maxFPS: Int
}

public enum HostHardwareEncoderCapabilityDiscovery {
  typealias Probe = @Sendable (
    HostHardwareEncoderProbeConfiguration
  ) async -> HostHardwareEncoderProbeResult

  public static func discover(
    target: HostHardwareEncoderCapabilityTarget
  ) async -> HostDiscoveredEncoderCapabilities? {
    await discover(target: target) { configuration in
      await HostHardwareEncoderProbe.probe(configuration: configuration)
    }
  }

  static func discover(
    target: HostHardwareEncoderCapabilityTarget,
    probe: Probe
  ) async -> HostDiscoveredEncoderCapabilities? {
    var bestH264FPS: Int?
    var bestHEVCFPS: Int?
    for fps in target.frameRateCandidates {
      guard !Task.isCancelled else { return nil }
      let h264 = await probe(configuration(codec: .h264, target: target, fps: fps))
      guard !Task.isCancelled else { return nil }
      let h265 = await probe(configuration(codec: .h265, target: target, fps: fps))
      guard !Task.isCancelled else { return nil }

      if h264.isAvailable, bestH264FPS == nil { bestH264FPS = fps }
      if h265.isAvailable, bestHEVCFPS == nil { bestHEVCFPS = fps }
      if h264.isAvailable, h265.isAvailable {
        return capabilities(target: target, fps: fps, h264: true, h265: true)
      }
    }
    // Prefer the H.264 compatibility baseline when no exact frame-rate tier
    // was proven by both codecs. Never combine results from different tiers
    // under one shared maxFPS.
    if let bestH264FPS {
      return capabilities(target: target, fps: bestH264FPS, h264: true, h265: false)
    }
    if let bestHEVCFPS {
      return capabilities(target: target, fps: bestHEVCFPS, h264: false, h265: true)
    }
    return nil
  }

  private static func configuration(
    codec: HostPipelineCodec,
    target: HostHardwareEncoderCapabilityTarget,
    fps: Int
  ) -> HostHardwareEncoderProbeConfiguration {
    HostHardwareEncoderProbeConfiguration(
      codec: codec,
      width: target.width,
      height: target.height,
      framesPerSecond: fps,
      sourcePixelFormat: target.sourcePixelFormat
    )
  }

  private static func capabilities(
    target: HostHardwareEncoderCapabilityTarget,
    fps: Int,
    h264: Bool,
    h265: Bool
  ) -> HostDiscoveredEncoderCapabilities {
    HostDiscoveredEncoderCapabilities(
      h264Hardware: h264,
      h265Hardware: h265,
      maxWidth: target.width,
      maxHeight: target.height,
      maxFPS: fps
    )
  }
}
