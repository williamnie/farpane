import CoreGraphics
import XCTest

@testable import VideoPipeline

private final class HostMediaPipelineTestResult: @unchecked Sendable {
  private let lock = NSLock()
  private var accessUnit: HostMediaAccessUnit?
  private var state: HostEncoderRuntimeState?
  private var error: Error?

  func record(accessUnit: HostMediaAccessUnit) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard self.accessUnit == nil else { return false }
    self.accessUnit = accessUnit
    return true
  }

  func record(state: HostEncoderRuntimeState) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard self.state == nil else { return false }
    self.state = state
    return true
  }

  func record(error: Error) {
    lock.lock()
    defer { lock.unlock() }
    self.error = error
  }

  func snapshot() -> (HostMediaAccessUnit?, HostEncoderRuntimeState?, Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (accessUnit, state, error)
  }
}

final class HostMediaPipelineTests: XCTestCase {
  func testAuthorizedScreenCaptureReachesHardwareEncoder() async throws {
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission is not granted to the test process")
    }
    guard HostH264Encoder.hardwareEncodingSupported else {
      throw XCTSkip("H.264 hardware encode is unavailable on this machine")
    }

    let (accessUnit, state, error) = try await runAuthorizedPipeline(codec: .h264)
    XCTAssertNil(error)
    XCTAssertEqual(state?.hardwareAccelerated, true)
    XCTAssertEqual(state?.softwareFallback, false)
    XCTAssertFalse(state?.encoderID.isEmpty ?? true)
    XCTAssertEqual(accessUnit?.codec, .h264)
    XCTAssertEqual(accessUnit?.isKeyframe, true)
    XCTAssertEqual(accessUnit?.hasParameterSets, true)
    XCTAssertLessThanOrEqual(accessUnit?.logicalRawFrameCopyCount ?? .max, 1)
    XCTAssertFalse(accessUnit?.data.isEmpty ?? true)
  }

  func testAuthorizedScreenCaptureReachesHardwareHEVCEncoder() async throws {
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission is not granted to the test process")
    }
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }

    let (accessUnit, state, error) = try await runAuthorizedPipeline(codec: .h265)
    XCTAssertNil(error)
    XCTAssertEqual(state?.hardwareAccelerated, true)
    XCTAssertEqual(state?.softwareFallback, false)
    XCTAssertFalse(state?.encoderID.isEmpty ?? true)
    XCTAssertEqual(accessUnit?.codec, .h265)
    XCTAssertEqual(accessUnit?.isKeyframe, true)
    XCTAssertEqual(accessUnit?.hasParameterSets, true)
    XCTAssertLessThanOrEqual(accessUnit?.logicalRawFrameCopyCount ?? .max, 1)
    guard let data = accessUnit?.data else {
      return XCTFail("HEVC pipeline returned no access unit")
    }
    let packet = try HEVCEncodedPacket(data: data, declaredFormat: .avcc)
    XCTAssertTrue(packet.isKeyframe)
    XCTAssertNotNil(packet.parameterSets[32])
    XCTAssertNotNil(packet.parameterSets[33])
    XCTAssertNotNil(packet.parameterSets[34])
  }

  private func runAuthorizedPipeline(
    codec: HostPipelineCodec
  ) async throws -> (HostMediaAccessUnit?, HostEncoderRuntimeState?, Error?) {
    let accessUnitReady = expectation(description: "captured frame encoded as \(codec.rawValue)")
    let stateReady = expectation(description: "hardware encoder state")
    let result = HostMediaPipelineTestResult()
    let pipeline = HostMediaPipeline(
      configuration: HostMediaPipelineConfiguration(
        codec: codec,
        displayIndex: 0,
        width: 256,
        height: 144,
        framesPerSecond: 15,
        bitRate: 500_000
      ),
      onAccessUnit: { accessUnit in
        if result.record(accessUnit: accessUnit) { accessUnitReady.fulfill() }
      },
      onState: { state in
        if result.record(state: state) { stateReady.fulfill() }
      },
      onError: { error in result.record(error: error) }
    )

    do {
      try await pipeline.start()
      await fulfillment(of: [accessUnitReady, stateReady], timeout: 8)
    } catch {
      await pipeline.stop()
      throw error
    }
    await pipeline.stop()

    return result.snapshot()
  }
}
