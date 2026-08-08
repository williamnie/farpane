import XCTest

@testable import VideoPipeline

private final class HostCapabilityProbeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var configurations: [HostHardwareEncoderProbeConfiguration] = []

  func record(_ configuration: HostHardwareEncoderProbeConfiguration) {
    lock.lock()
    configurations.append(configuration)
    lock.unlock()
  }

  func frameRates(codec: HostPipelineCodec) -> [Int] {
    lock.lock()
    defer { lock.unlock() }
    return configurations
      .filter { $0.codec == codec }
      .map(\.framesPerSecond)
  }
}

final class HostHardwareEncoderCapabilitiesTests: XCTestCase {
  func testAdvertisesBothCodecsOnlyAtAnExactlyProvenSharedTier() async throws {
    let target = try XCTUnwrap(target(maxFPS: 60))
    let recorder = HostCapabilityProbeRecorder()
    let discovered = await HostHardwareEncoderCapabilityDiscovery.discover(
      target: target
    ) { configuration in
      recorder.record(configuration)
      let available = configuration.codec == .h264 || configuration.framesPerSecond <= 30
      return result(configuration, available: available)
    }

    XCTAssertEqual(discovered, HostDiscoveredEncoderCapabilities(
      h264Hardware: true,
      h265Hardware: true,
      maxWidth: 2_560,
      maxHeight: 1_440,
      maxFPS: 30
    ))
    XCTAssertEqual(recorder.frameRates(codec: .h264), [60, 30])
    XCTAssertEqual(recorder.frameRates(codec: .h265), [60, 30])
  }

  func testFallsBackToProvenH264CompatibilityWhenNoTierIsShared() async throws {
    let target = try XCTUnwrap(target(maxFPS: 60))
    let discovered = await HostHardwareEncoderCapabilityDiscovery.discover(
      target: target
    ) { configuration in
      let available = configuration.codec == .h264 && configuration.framesPerSecond == 60
      return result(configuration, available: available)
    }

    XCTAssertEqual(discovered, HostDiscoveredEncoderCapabilities(
      h264Hardware: true,
      h265Hardware: false,
      maxWidth: 2_560,
      maxHeight: 1_440,
      maxFPS: 60
    ))
  }

  func testFailsClosedWhenNoCodecCompletesTargetProbe() async throws {
    let target = try XCTUnwrap(target(maxFPS: 30))
    let discovered = await HostHardwareEncoderCapabilityDiscovery.discover(
      target: target
    ) { configuration in
      result(configuration, available: false)
    }

    XCTAssertNil(discovered)
  }

  func testTargetRejectsUnsafeDisplayEnvelope() {
    XCTAssertNil(HostHardwareEncoderCapabilityTarget(
      width: 16_384,
      height: 16_384,
      maximumFramesPerSecond: 60
    ))
  }

  private func target(maxFPS: Int) -> HostHardwareEncoderCapabilityTarget? {
    HostHardwareEncoderCapabilityTarget(
      width: 2_560,
      height: 1_440,
      maximumFramesPerSecond: maxFPS
    )
  }

  private func result(
    _ configuration: HostHardwareEncoderProbeConfiguration,
    available: Bool
  ) -> HostHardwareEncoderProbeResult {
    HostHardwareEncoderProbeResult(
      configuration: configuration,
      hardwareAccelerated: available,
      encoderID: available ? "test-hardware-encoder" : nil,
      producedKeyframeWithParameterSets: available,
      failure: available ? nil : .softwareFallback
    )
  }
}
