import CoreGraphics
import CoreVideo
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

private final class HostMediaStageTestRecorder: HostMediaStageRecording, @unchecked Sendable {
  struct Event: Equatable {
    let stage: HostMediaStage
    let presentationTimeUS: UInt64
    let byteCount: Int
  }

  private let lock = NSLock()
  private var events: [Event] = []

  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {
    lock.lock()
    defer { lock.unlock() }
    events.append(Event(
      stage: stage,
      presentationTimeUS: presentationTimeUS,
      byteCount: byteCount
    ))
  }

  func snapshot() -> [Event] {
    lock.lock()
    defer { lock.unlock() }
    return events
  }
}

private final class HostMediaResetResult: @unchecked Sendable {
  private let lock = NSLock()
  private var accessUnits: [HostMediaAccessUnit] = []
  private var errors: [Error] = []

  func record(accessUnit: HostMediaAccessUnit) -> Int {
    lock.lock()
    defer { lock.unlock() }
    accessUnits.append(accessUnit)
    return accessUnits.count
  }

  func record(error: Error) {
    lock.lock()
    errors.append(error)
    lock.unlock()
  }

  func snapshot() -> ([HostMediaAccessUnit], [Error]) {
    lock.lock()
    defer { lock.unlock() }
    return (accessUnits, errors)
  }
}

private final class HostMediaResetPipelineReference: @unchecked Sendable {
  private let lock = NSLock()
  private weak var pipeline: HostMediaPipeline?

  func bind(_ pipeline: HostMediaPipeline) {
    lock.lock()
    self.pipeline = pipeline
    lock.unlock()
  }

  func recover() {
    lock.lock()
    let pipeline = pipeline
    lock.unlock()
    pipeline?.recoverFromEncodedPacketDrop()
  }
}

private final class HostMediaDecoderRecoveryResult: @unchecked Sendable {
  private let lock = NSLock()
  private var dimensions: [(width: Int, height: Int)] = []

  func record(_ pixelBuffer: CVPixelBuffer) -> Int {
    lock.lock()
    defer { lock.unlock() }
    dimensions.append((
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    ))
    return dimensions.count
  }

  func snapshot() -> [(width: Int, height: Int)] {
    lock.lock()
    defer { lock.unlock() }
    return dimensions
  }
}

final class HostMediaPipelineTests: XCTestCase {
  func testRawFrameHandoffKeepsTwoNewestWithoutReplacingActiveFrame() {
    var handoff = HostRawFrameHandoff<Int>()

    let first = handoff.enqueue(1)
    XCTAssertTrue(first.shouldScheduleWorker)
    XCTAssertFalse(first.supersededPendingFrame)
    XCTAssertEqual(first.depth, 1)

    let second = handoff.enqueue(2)
    XCTAssertFalse(second.shouldScheduleWorker)
    XCTAssertFalse(second.supersededPendingFrame)
    XCTAssertEqual(second.depth, HostRawFrameHandoff<Int>.capacity)

    let third = handoff.enqueue(3)
    XCTAssertTrue(third.supersededPendingFrame)
    XCTAssertEqual(third.depth, HostRawFrameHandoff<Int>.capacity)
    XCTAssertEqual(handoff.beginNext(), 2)

    let fourth = handoff.enqueue(4)
    XCTAssertTrue(fourth.supersededPendingFrame)
    XCTAssertEqual(fourth.depth, HostRawFrameHandoff<Int>.capacity)
    XCTAssertEqual(handoff.finishActive(), 1)
    XCTAssertEqual(handoff.beginNext(), 4)

    let cancelled = handoff.enqueue(5)
    XCTAssertFalse(cancelled.supersededPendingFrame)
    let cancellation = handoff.cancelPending()
    XCTAssertEqual(cancellation.cancelledPendingFrames, 1)
    XCTAssertEqual(cancellation.depth, 1)
    XCTAssertEqual(handoff.finishActive(), 0)
    XCTAssertNil(handoff.beginNext())

    let replacementWorker = handoff.enqueue(6)
    XCTAssertTrue(replacementWorker.shouldScheduleWorker)
    XCTAssertEqual(replacementWorker.depth, 1)
  }

  func testPipelineInstrumentsCaptureSupersededAtZeroBeforeFrames() {
    let pipeline = HostMediaPipeline(
      configuration: HostMediaPipelineConfiguration(
        displayIndex: 0,
        width: 256,
        height: 144,
        framesPerSecond: 15,
        bitRate: 500_000
      ),
      onAccessUnit: { _ in },
      onState: { _ in },
      onError: { _ in }
    )

    let snapshot = pipeline.telemetry.snapshot()
    XCTAssertEqual(snapshot.drops.captureSuperseded, 0)
    XCTAssertEqual(snapshot.rawFrameQueueDepth, 0)
    XCTAssertEqual(snapshot.maximumRawFrameQueueDepth, 0)
  }

  func testEncoderGenerationGateRejectsCallbacksAfterReset() {
    var gate = HostMediaEncoderGenerationGate()
    let first = gate.beginEncoder()
    XCTAssertTrue(gate.accepts(first))

    gate.invalidateCurrent()
    XCTAssertFalse(gate.accepts(first))

    let replacement = gate.beginEncoder()
    XCTAssertNotEqual(replacement, first)
    XCTAssertTrue(gate.accepts(replacement))
  }

  func testBackpressureRecoveryKeepsH264EncoderAndRequestsIDR() async throws {
    guard HostH264Encoder.hardwareEncodingSupported else {
      throw XCTSkip("H.264 hardware encode is unavailable on this machine")
    }
    _ = try await captureBackpressureResetAccessUnits(codec: .h264)
  }

  func testBackpressureRecoveryKeepsHEVCEncoderAndRequestsIDR() async throws {
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }
    let accessUnits = try await captureBackpressureResetAccessUnits(codec: .h265)
    try await assertHEVCDecoderRecoversAfterEncoderReset(accessUnits: accessUnits)
  }

  func testAuthorizedScreenCaptureReachesHardwareEncoder() async throws {
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission is not granted to the test process")
    }
    guard HostH264Encoder.hardwareEncodingSupported else {
      throw XCTSkip("H.264 hardware encode is unavailable on this machine")
    }

    let (accessUnit, state, error, stages, telemetry) = try await runAuthorizedPipeline(
      codec: .h264
    )
    XCTAssertNil(error)
    XCTAssertEqual(state?.hardwareAccelerated, true)
    XCTAssertEqual(state?.softwareFallback, false)
    XCTAssertFalse(state?.encoderID.isEmpty ?? true)
    XCTAssertEqual(accessUnit?.codec, .h264)
    XCTAssertEqual(accessUnit?.isKeyframe, true)
    XCTAssertEqual(accessUnit?.hasParameterSets, true)
    XCTAssertLessThanOrEqual(accessUnit?.logicalRawFrameCopyCount ?? .max, 1)
    XCTAssertFalse(accessUnit?.data.isEmpty ?? true)
    assertCorrelatedStages(accessUnit: accessUnit, events: stages)
    assertTelemetry(telemetry, codec: .h264, accessUnit: accessUnit, state: state)
  }

  func testAuthorizedScreenCaptureReachesHardwareHEVCEncoder() async throws {
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission is not granted to the test process")
    }
    guard HostHEVCEncoder.hardwareEncodingSupported else {
      throw XCTSkip("HEVC hardware encode is unavailable on this machine")
    }

    let (accessUnit, state, error, stages, telemetry) = try await runAuthorizedPipeline(
      codec: .h265
    )
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
    assertCorrelatedStages(accessUnit: accessUnit, events: stages)
    assertTelemetry(telemetry, codec: .h265, accessUnit: accessUnit, state: state)
  }

  private func runAuthorizedPipeline(
    codec: HostPipelineCodec
  ) async throws -> (
    HostMediaAccessUnit?,
    HostEncoderRuntimeState?,
    Error?,
    [HostMediaStageTestRecorder.Event],
    HostMediaTelemetrySnapshot
  ) {
    let accessUnitReady = expectation(description: "captured frame encoded as \(codec.rawValue)")
    let stateReady = expectation(description: "hardware encoder state")
    let result = HostMediaPipelineTestResult()
    let stageRecorder = HostMediaStageTestRecorder()
    let pipeline = HostMediaPipeline(
      configuration: HostMediaPipelineConfiguration(
        codec: codec,
        displayIndex: 0,
        width: 256,
        height: 144,
        framesPerSecond: 15,
        bitRate: 500_000
      ),
      stageRecorder: stageRecorder,
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

    let snapshot = result.snapshot()
    return (
      snapshot.0,
      snapshot.1,
      snapshot.2,
      stageRecorder.snapshot(),
      pipeline.telemetry.snapshot()
    )
  }

  private func captureBackpressureResetAccessUnits(
    codec: HostPipelineCodec,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> [HostMediaAccessUnit] {
    guard CGPreflightScreenCaptureAccess() else {
      throw XCTSkip("Screen Recording permission is not granted to the test process")
    }
    let firstReady = expectation(description: "first \(codec.rawValue) generation")
    let replacementReady = expectation(description: "replacement \(codec.rawValue) generation")
    let result = HostMediaResetResult()
    let reference = HostMediaResetPipelineReference()
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
        switch result.record(accessUnit: accessUnit) {
        case 1:
          reference.recover()
          firstReady.fulfill()
        case 2:
          replacementReady.fulfill()
        default:
          break
        }
      },
      onState: { _ in },
      onError: { error in result.record(error: error) }
    )
    reference.bind(pipeline)

    do {
      try await pipeline.start()
      await fulfillment(of: [firstReady, replacementReady], timeout: 8)
    } catch {
      await pipeline.stop()
      throw error
    }
    await pipeline.stop()

    let (accessUnits, errors) = result.snapshot()
    XCTAssertTrue(errors.isEmpty, "unexpected errors: \(errors)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(accessUnits.count, 2, file: file, line: line)
    guard accessUnits.count >= 2 else { return accessUnits }
    let first = accessUnits[0]
    let replacement = accessUnits[1]
    XCTAssertTrue(first.isKeyframe, file: file, line: line)
    XCTAssertTrue(first.hasParameterSets, file: file, line: line)
    XCTAssertTrue(replacement.isKeyframe, file: file, line: line)
    XCTAssertTrue(replacement.hasParameterSets, file: file, line: line)
    XCTAssertGreaterThan(
      replacement.presentationTimeUS,
      first.presentationTimeUS,
      file: file,
      line: line
    )
    return accessUnits
  }

  private func assertHEVCDecoderRecoversAfterEncoderReset(
    accessUnits: [HostMediaAccessUnit],
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    guard accessUnits.count >= 2 else {
      return XCTFail("encoder reset returned fewer than two access units", file: file, line: line)
    }
    let firstDecoded = expectation(description: "first HEVC generation decoded")
    let replacementDecoded = expectation(description: "replacement HEVC generation decoded")
    let result = HostMediaDecoderRecoveryResult()
    let metrics = PipelineMetrics(
      inputWidth: 256,
      inputHeight: 144,
      inputFPS: 15,
      selectedGPU: "VideoToolbox",
      source: "host-reset-recovery-test"
    )
    let decoder = LiveHEVCDecoder(metrics: metrics) { pixelBuffer, _ in
      switch result.record(pixelBuffer) {
      case 1: firstDecoded.fulfill()
      case 2: replacementDecoded.fulfill()
      default: break
      }
    }
    defer { decoder.invalidate() }

    let first = accessUnits[0]
    let firstPacket = try HEVCEncodedPacket(data: first.data, declaredFormat: .avcc)
    try decoder.submit(
      firstPacket,
      sequence: 1,
      timestampUS: first.presentationTimeUS,
      fps: 15
    )
    await fulfillment(of: [firstDecoded], timeout: 8)

    // Model a viewer-side decoder reset after the encoded packet loss. The
    // replacement generation must be self-contained enough to rebuild the
    // production decoder without any parameter-set state from generation 1.
    decoder.invalidate()
    let replacement = accessUnits[1]
    let replacementPacket = try HEVCEncodedPacket(
      data: replacement.data,
      declaredFormat: .avcc
    )
    try decoder.submit(
      replacementPacket,
      sequence: 2,
      timestampUS: replacement.presentationTimeUS,
      fps: 15
    )
    await fulfillment(of: [replacementDecoded], timeout: 8)

    XCTAssertEqual(
      result.snapshot().map { [$0.width, $0.height] },
      [[256, 144], [256, 144]],
      file: file,
      line: line
    )
    let report = metrics.snapshot()
    XCTAssertEqual(report.submittedFrames, 2, file: file, line: line)
    XCTAssertEqual(report.decodedFrames, 2, file: file, line: line)
    XCTAssertEqual(report.decodeErrors, 0, file: file, line: line)
    XCTAssertTrue(report.hardwareDecodeActive, file: file, line: line)
    XCTAssertEqual(report.observedWidth, 256, file: file, line: line)
    XCTAssertEqual(report.observedHeight, 144, file: file, line: line)
  }

  private func assertCorrelatedStages(
    accessUnit: HostMediaAccessUnit?,
    events: [HostMediaStageTestRecorder.Event],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let accessUnit else {
      return XCTFail("pipeline returned no access unit", file: file, line: line)
    }
    let correlated = events.filter {
      $0.presentationTimeUS == accessUnit.presentationTimeUS
    }
    XCTAssertEqual(
      correlated.map(\.stage),
      [.capture, .encodeSubmit, .packetReady],
      file: file,
      line: line
    )
    XCTAssertEqual(correlated.last?.byteCount, accessUnit.data.count, file: file, line: line)
  }

  private func assertTelemetry(
    _ telemetry: HostMediaTelemetrySnapshot,
    codec: HostPipelineCodec,
    accessUnit: HostMediaAccessUnit?,
    state: HostEncoderRuntimeState?,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(telemetry.codec, codec, file: file, line: line)
    XCTAssertEqual(telemetry.requestedWidth, 256, file: file, line: line)
    XCTAssertEqual(telemetry.requestedHeight, 144, file: file, line: line)
    XCTAssertEqual(telemetry.requestedFPS, 15, file: file, line: line)
    XCTAssertEqual(telemetry.captureWidth, 256, file: file, line: line)
    XCTAssertEqual(telemetry.captureHeight, 144, file: file, line: line)
    XCTAssertNotNil(telemetry.pixelFormat, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.captureCallbacks, telemetry.validFrames, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.validFrames, 1, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.actualFPS, 0, file: file, line: line)
    XCTAssertEqual(telemetry.captureContentState, .highMotion, file: file, line: line)
    XCTAssertEqual(telemetry.captureTargetFPS, 15, file: file, line: line)
    XCTAssertEqual(telemetry.captureAppliedFPS, 15, file: file, line: line)
    XCTAssertEqual(telemetry.capturePressureLevel, .none, file: file, line: line)
    XCTAssertEqual(telemetry.captureCadenceTransitions, 0, file: file, line: line)
    XCTAssertEqual(telemetry.capturePressureTransitions, 0, file: file, line: line)
    XCTAssertEqual(
      telemetry.captureConfigurationUpdateAttempts,
      0,
      file: file,
      line: line
    )
    XCTAssertEqual(
      telemetry.captureConfigurationUpdateFailures,
      0,
      file: file,
      line: line
    )
    XCTAssertFalse(
      telemetry.captureConfigurationUpdateInFlight,
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      telemetry.maximumLogicalRawFrameCopyCount,
      1,
      file: file,
      line: line
    )
    XCTAssertEqual(telemetry.rawFrameQueueDepth, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      telemetry.maximumRawFrameQueueDepth,
      1,
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      telemetry.maximumRawFrameQueueDepth,
      HostRawFrameHandoff<Int>.capacity,
      file: file,
      line: line
    )
    XCTAssertNotNil(telemetry.drops.captureSuperseded, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.encodeSubmissions, 1, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.encodedPackets, 1, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.maximumEncodeInFlight, 1, file: file, line: line)
    XCTAssertNotNil(telemetry.encodeLatencyP50MS, file: file, line: line)
    XCTAssertNotNil(telemetry.encodeLatencyP95MS, file: file, line: line)
    XCTAssertNotNil(telemetry.encodeLatencyP99MS, file: file, line: line)
    XCTAssertNotNil(telemetry.latestEncodeLatencyMS, file: file, line: line)
    XCTAssertLessThanOrEqual(
      telemetry.encodeLatencyP50MS ?? .infinity,
      telemetry.encodeLatencyP95MS ?? -.infinity,
      file: file,
      line: line
    )
    XCTAssertLessThanOrEqual(
      telemetry.encodeLatencyP95MS ?? .infinity,
      telemetry.encodeLatencyP99MS ?? -.infinity,
      file: file,
      line: line
    )
    XCTAssertGreaterThanOrEqual(
      telemetry.encodedBytes,
      UInt64(accessUnit?.data.count ?? 0),
      file: file,
      line: line
    )
    XCTAssertGreaterThan(telemetry.encodedBitRateBPS, 0, file: file, line: line)
    XCTAssertGreaterThanOrEqual(telemetry.keyframes, 1, file: file, line: line)
    XCTAssertEqual(telemetry.recentSendOutcomeCount, 0, file: file, line: line)
    XCTAssertEqual(telemetry.recentSendDropRate, 0, file: file, line: line)
    XCTAssertEqual(telemetry.consecutiveSendDrops, 0, file: file, line: line)
    XCTAssertEqual(telemetry.hardwareAccelerated, state?.hardwareAccelerated, file: file, line: line)
    XCTAssertEqual(telemetry.softwareFallback, state?.softwareFallback, file: file, line: line)
    XCTAssertEqual(telemetry.encoderID, state?.encoderID, file: file, line: line)
    XCTAssertGreaterThan(telemetry.runtimeSeconds, 0, file: file, line: line)
  }
}
