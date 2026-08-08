import XCTest

@testable import VideoPipeline

final class HostProcessSamplerTests: XCTestCase {
  func testSamplesCurrentProcessAndNonSensitivePowerState() {
    let sampler = HostProcessSampler()
    let sample = sampler.sample()

    XCTAssertGreaterThanOrEqual(sample.cpuPercent, 0)
    XCTAssertGreaterThan(sample.residentBytes, 0)
    XCTAssertGreaterThan(sample.physicalFootprintBytes, 0)
    XCTAssertGreaterThan(sample.threadCount, 0)
    XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(
      sample.thermalState
    ))
    XCTAssertTrue(["ac", "battery", "offline", "unknown"].contains(sample.powerSource))
  }

  func testTelemetryRetainsLatestAndPeakProcessSamples() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 640,
        height: 360,
        framesPerSecond: 30,
        bitRate: 1_000_000
      ),
      stageRecorder: HostMediaNoopProcessStageRecorder()
    )

    telemetry.sampleProcessNow()
    telemetry.sampleProcessNow()
    let snapshot = telemetry.snapshot()

    XCTAssertGreaterThanOrEqual(snapshot.processSamples, 2)
    XCTAssertGreaterThanOrEqual(snapshot.processCPUPercent ?? -1, 0)
    XCTAssertGreaterThanOrEqual(
      snapshot.peakProcessCPUPercent,
      snapshot.processCPUPercent ?? 0
    )
    XCTAssertGreaterThan(snapshot.residentBytes ?? 0, 0)
    XCTAssertGreaterThanOrEqual(snapshot.peakResidentBytes, snapshot.residentBytes ?? 0)
    XCTAssertGreaterThan(snapshot.physicalFootprintBytes ?? 0, 0)
    XCTAssertGreaterThanOrEqual(
      snapshot.peakPhysicalFootprintBytes,
      snapshot.physicalFootprintBytes ?? 0
    )
    XCTAssertGreaterThan(snapshot.threadCount ?? 0, 0)
    XCTAssertGreaterThanOrEqual(snapshot.peakThreadCount, snapshot.threadCount ?? 0)
    XCTAssertNotNil(snapshot.thermalState)
    XCTAssertNotNil(snapshot.powerSource)
    XCTAssertNotNil(snapshot.lowPowerModeEnabled)
    let backpressure = telemetry.captureBackpressure()
    XCTAssertEqual(backpressure.thermalState, snapshot.thermalState)
    XCTAssertEqual(backpressure.lowPowerModeEnabled, snapshot.lowPowerModeEnabled)
  }

  func testTelemetrySamplesProcessOnOneSecondCadence() async throws {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 640,
        height: 360,
        framesPerSecond: 30,
        bitRate: 1_000_000
      ),
      stageRecorder: HostMediaNoopProcessStageRecorder()
    )

    try await Task.sleep(nanoseconds: 1_200_000_000)

    let snapshot = telemetry.snapshot()
    XCTAssertGreaterThanOrEqual(snapshot.processSamples, 1)
    XCTAssertGreaterThan(snapshot.residentBytes ?? 0, 0)
    XCTAssertGreaterThan(snapshot.threadCount ?? 0, 0)
  }
}

private struct HostMediaNoopProcessStageRecorder: HostMediaStageRecording {
  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {}
}
