import CoreVideo
import XCTest

@testable import VideoPipeline

final class HostHardwareEncoderProbeTests: XCTestCase {
  func testProbesRealH264HardwareAt1080p30() async throws {
    guard HostH264Encoder.hardwareEncodingSupported else {
      throw XCTSkip("H.264 hardware encode is unavailable on this machine")
    }
    let result = await HostHardwareEncoderProbe.probe(configuration: configuration(.h264))

    XCTAssertTrue(result.isAvailable)
    XCTAssertTrue(result.hardwareAccelerated)
    XCTAssertTrue(result.producedKeyframeWithParameterSets)
    XCTAssertFalse(result.encoderID?.isEmpty ?? true)
    XCTAssertNil(result.failure)
  }

  func testProbesRealHEVCHardwareAt1080p30() async throws {
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }
    let result = await HostHardwareEncoderProbe.probe(configuration: configuration(.h265))

    XCTAssertTrue(result.isAvailable)
    XCTAssertTrue(result.hardwareAccelerated)
    XCTAssertTrue(result.producedKeyframeWithParameterSets)
    XCTAssertFalse(result.encoderID?.isEmpty ?? true)
    XCTAssertNil(result.failure)
  }

  func testProbesRealH264HardwareAt4K30() async throws {
    guard HostH264Encoder.hardwareEncodingSupported else {
      throw XCTSkip("H.264 hardware encode is unavailable on this machine")
    }
    let result = await HostHardwareEncoderProbe.probe(
      configuration: configuration(.h264, width: 3_840, height: 2_160)
    )

    XCTAssertTrue(result.isAvailable)
    XCTAssertTrue(result.hardwareAccelerated)
    XCTAssertTrue(result.producedKeyframeWithParameterSets)
    XCTAssertFalse(result.encoderID?.isEmpty ?? true)
    XCTAssertNil(result.failure)
  }

  func testProbesRealHEVCHardwareAt4K30() async throws {
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }
    let result = await HostHardwareEncoderProbe.probe(
      configuration: configuration(.h265, width: 3_840, height: 2_160)
    )

    XCTAssertTrue(result.isAvailable)
    XCTAssertTrue(result.hardwareAccelerated)
    XCTAssertTrue(result.producedKeyframeWithParameterSets)
    XCTAssertFalse(result.encoderID?.isEmpty ?? true)
    XCTAssertNil(result.failure)
  }

  func testRejectsUnboundedProbeBeforeAllocatingPixelBuffer() async {
    let result = await HostHardwareEncoderProbe.probe(
      configuration: HostHardwareEncoderProbeConfiguration(
        codec: .h265,
        width: 16_384,
        height: 16_384,
        framesPerSecond: 60
      )
    )

    XCTAssertFalse(result.isAvailable)
    XCTAssertEqual(result.failure, .invalidConfiguration)
    XCTAssertNil(result.encoderID)
  }

  private func configuration(
    _ codec: HostPipelineCodec,
    width: Int = 1_920,
    height: Int = 1_080
  ) -> HostHardwareEncoderProbeConfiguration {
    HostHardwareEncoderProbeConfiguration(
      codec: codec,
      width: width,
      height: height,
      framesPerSecond: 30,
      sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    )
  }
}
