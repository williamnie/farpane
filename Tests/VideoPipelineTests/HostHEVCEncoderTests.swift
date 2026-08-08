import CoreMedia
import CoreVideo
import XCTest

@testable import VideoPipeline

private final class HostHEVCEncoderTestResult: @unchecked Sendable {
  private let lock = NSLock()
  private var accessUnits: [HostHEVCAccessUnit] = []
  private var runtimeState: HostEncoderRuntimeState?
  private var callbackError: HostHEVCEncoderError?

  func set(accessUnit: HostHEVCAccessUnit) {
    lock.lock()
    defer { lock.unlock() }
    accessUnits.append(accessUnit)
  }

  func set(runtimeState: HostEncoderRuntimeState) {
    lock.lock()
    defer { lock.unlock() }
    self.runtimeState = runtimeState
  }

  func set(error: HostHEVCEncoderError) {
    lock.lock()
    defer { lock.unlock() }
    callbackError = error
  }

  func snapshot() -> ([HostHEVCAccessUnit], HostEncoderRuntimeState?, HostHEVCEncoderError?) {
    lock.lock()
    defer { lock.unlock() }
    return (accessUnits, runtimeState, callbackError)
  }
}

final class HostHEVCEncoderTests: XCTestCase {
  func testRapidHardwareHEVCSubmissionKeepsFrameContextSingleOwner() throws {
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }
    let resultBox = HostHEVCEncoderTestResult()
    let encoder = try HostHEVCEncoder(
      configuration: HostHEVCEncoderConfiguration(
        width: 128,
        height: 128,
        framesPerSecond: 60,
        averageBitRate: 500_000
      ),
      sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      onAccessUnit: { resultBox.set(accessUnit: $0) },
      onState: { resultBox.set(runtimeState: $0) },
      onError: { resultBox.set(error: $0) }
    )
    let pixelBuffer = try makeNV12Buffer(width: 128, height: 128)

    // Submit faster than real time so VideoToolbox can exercise its
    // synchronous/asynchronous drop paths. A noErr submission transfers the
    // retained frame context exclusively to the output callback.
    for frameNumber in 1...2_000 {
      try encoder.encode(
        pixelBuffer: pixelBuffer,
        presentationTime: CMTime(value: Int64(frameNumber), timescale: 60),
        logicalRawFrameCopyCount: 0
      )
    }
    encoder.invalidate()

    let (accessUnits, state, callbackError) = resultBox.snapshot()
    XCTAssertFalse(accessUnits.isEmpty)
    XCTAssertEqual(state?.hardwareAccelerated, true)
    if let callbackError {
      guard case .frameDropped = callbackError else {
        return XCTFail("unexpected HEVC callback error: \(callbackError)")
      }
    }
  }

  func testHardwareHEVCEncodeReportsStateAndRequestedIDR() throws {
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }
    let accessUnitReady = expectation(description: "encoded HEVC access units")
    accessUnitReady.expectedFulfillmentCount = 2
    let stateReady = expectation(description: "HEVC hardware state readback")
    let resultBox = HostHEVCEncoderTestResult()
    let encoder = try HostHEVCEncoder(
      configuration: HostHEVCEncoderConfiguration(
        width: 128,
        height: 128,
        framesPerSecond: 30,
        averageBitRate: 500_000
      ),
      sourcePixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      onAccessUnit: { value in
        resultBox.set(accessUnit: value)
        accessUnitReady.fulfill()
      },
      onState: { value in
        resultBox.set(runtimeState: value)
        stateReady.fulfill()
      },
      onError: { error in resultBox.set(error: error) }
    )
    let pixelBuffer = try makeNV12Buffer(width: 128, height: 128)
    try encoder.encode(
      pixelBuffer: pixelBuffer,
      presentationTime: CMTime(value: 1, timescale: 30),
      logicalRawFrameCopyCount: 0
    )
    encoder.requestKeyframe()
    try encoder.encode(
      pixelBuffer: pixelBuffer,
      presentationTime: CMTime(value: 2, timescale: 30),
      logicalRawFrameCopyCount: 0
    )
    wait(for: [accessUnitReady, stateReady], timeout: 5)
    encoder.invalidate()

    let (results, state, error) = resultBox.snapshot()
    XCTAssertNil(error)
    XCTAssertEqual(state?.hardwareAccelerated, true)
    XCTAssertEqual(state?.softwareFallback, false)
    XCTAssertFalse(state?.encoderID.isEmpty ?? true)
    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results.allSatisfy(\.isKeyframe))
    XCTAssertTrue(results.allSatisfy(\.hasParameterSets))
    XCTAssertTrue(results.allSatisfy { $0.logicalRawFrameCopyCount == 0 })
    XCTAssertTrue(results.allSatisfy { !$0.data.isEmpty })
    let parsed = try results.map {
      try HEVCEncodedPacket(data: $0.data, declaredFormat: .avcc)
    }
    XCTAssertTrue(parsed.allSatisfy(\.isKeyframe))
    XCTAssertTrue(parsed.allSatisfy { $0.parameterSets[32] != nil })
    XCTAssertTrue(parsed.allSatisfy { $0.parameterSets[33] != nil })
    XCTAssertTrue(parsed.allSatisfy { $0.parameterSets[34] != nil })
  }

  private func makeNV12Buffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &buffer
    )
    guard status == kCVReturnSuccess, let buffer else {
      throw NSError(domain: "HostHEVCEncoderTests", code: Int(status))
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      guard let address = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
      let fill: UInt8 = plane == 0 ? 16 : 128
      memset(
        address, Int32(fill),
        CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
          * CVPixelBufferGetHeightOfPlane(buffer, plane))
    }
    return buffer
  }
}
