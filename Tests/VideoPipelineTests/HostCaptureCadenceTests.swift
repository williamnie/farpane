import CoreMedia
import XCTest

@testable import VideoPipeline

final class HostCaptureCadenceTests: XCTestCase {
  func testPressureAssessmentReportsEveryCurrentTriggerInStableOrder() {
    let assessment = HostCaptureBackpressure(
      encodeInFlight: 2,
      latestEncodeLatencyMS: 100,
      recentSendOutcomeCount: 8,
      recentSendDropRate: 0.20,
      consecutiveSendDrops: 4,
      encodedQueueDepth: 2,
      encodedQueueCapacity: 3,
      consecutiveEncodedQueueNearFullSamples: 3,
      networkDelayMS: 300,
      roundTripTimeMS: 260,
      responseDelayedSubscribers: 1,
      thermalState: "serious",
      lowPowerModeEnabled: true
    ).assessment(maximumFramesPerSecond: 30)

    XCTAssertEqual(assessment.level, .severe)
    XCTAssertEqual(assessment.causes, [
      .thermalState,
      .lowPowerMode,
      .encodeInFlight,
      .encodeLatency,
      .consecutiveSendDrops,
      .recentSendDropRate,
      .encodedQueue,
      .networkDelay,
      .roundTripTime,
      .responseDelayed,
    ])
    XCTAssertEqual(
      HostCaptureBackpressure.clear.assessment(maximumFramesPerSecond: 30),
      HostCapturePressureAssessment(level: .none, causes: [])
    )
  }

  func testThermalAndLowPowerStatesApplyEnvironmentalPressureCeilings() {
    XCTAssertEqual(environmentalPressure(thermalState: "nominal").level(
      maximumFramesPerSecond: 60
    ), .none)
    XCTAssertEqual(environmentalPressure(thermalState: "fair").level(
      maximumFramesPerSecond: 60
    ), .moderate)
    XCTAssertEqual(environmentalPressure(thermalState: "serious").level(
      maximumFramesPerSecond: 60
    ), .moderate)
    XCTAssertEqual(environmentalPressure(thermalState: "critical").level(
      maximumFramesPerSecond: 60
    ), .severe)
    XCTAssertEqual(environmentalPressure(
      thermalState: "nominal",
      lowPowerModeEnabled: true
    ).level(maximumFramesPerSecond: 60), .moderate)

    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 60,
      windowSize: 4,
      minimumDwellTime: 2,
      startedAtNanoseconds: 0
    )
    let fair = controller.observe(
      dirtyAreaRatio: 0.5,
      backpressure: environmentalPressure(thermalState: "fair"),
      nowNanoseconds: nanoseconds(1)
    )
    XCTAssertEqual(fair.pressureLevel, .moderate)
    XCTAssertEqual(fair.framesPerSecond, 15)

    let critical = controller.observe(
      dirtyAreaRatio: 0.5,
      backpressure: environmentalPressure(thermalState: "critical"),
      nowNanoseconds: nanoseconds(1.1)
    )
    XCTAssertEqual(critical.pressureLevel, .severe)
    XCTAssertEqual(critical.framesPerSecond, 5)
  }

  func testEncodePressureCapsImmediatelyAndRecoversAfterWindowAndDwell() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 60,
      windowSize: 4,
      minimumDwellTime: 2,
      startedAtNanoseconds: 0
    )
    let moderate = HostCaptureBackpressure(
      encodeInFlight: 2,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0
    )

    let capped = controller.observe(
      dirtyAreaRatio: 0.5,
      backpressure: moderate,
      nowNanoseconds: nanoseconds(1)
    )
    XCTAssertEqual(capped.contentState, .highMotion)
    XCTAssertEqual(capped.pressureLevel, .moderate)
    XCTAssertEqual(capped.framesPerSecond, 15)

    for time in [1.5, 2.0, 2.5] {
      let held = controller.observe(
        dirtyAreaRatio: 0.5,
        backpressure: .clear,
        nowNanoseconds: nanoseconds(time)
      )
      XCTAssertEqual(held.pressureLevel, .moderate)
      XCTAssertEqual(held.framesPerSecond, 15)
    }
    let recovered = controller.observe(
      dirtyAreaRatio: 0.5,
      backpressure: .clear,
      nowNanoseconds: nanoseconds(3)
    )
    XCTAssertEqual(recovered.pressureLevel, .none)
    XCTAssertEqual(recovered.framesPerSecond, 60)
  }

  func testSendDropWindowAppliesSevereCapAndMissingDirtyMetadataStaysBounded() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 60,
      windowSize: 4,
      minimumDwellTime: 2,
      startedAtNanoseconds: 0
    )
    let severe = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 8,
      recentSendDropRate: 0.25,
      consecutiveSendDrops: 0
    )

    let decision = controller.observe(
      dirtyAreaRatio: nil,
      backpressure: severe,
      nowNanoseconds: nanoseconds(1)
    )
    XCTAssertEqual(decision.contentState, .highMotion)
    XCTAssertFalse(decision.dirtyMetadataTrusted)
    XCTAssertEqual(decision.pressureLevel, .severe)
    XCTAssertEqual(decision.framesPerSecond, 5)
  }

  func testPressureThresholdsUseNegotiatedFrameBudget() {
    let moderate = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: 67,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0
    )
    let severe = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: 134,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0
    )
    XCTAssertEqual(moderate.level(maximumFramesPerSecond: 30), .moderate)
    XCTAssertEqual(severe.level(maximumFramesPerSecond: 30), .severe)
  }

  func testProductionEncodedQueueOccupancyAppliesBoundedPressure() {
    let transientNearFull = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0,
      encodedQueueDepth: 2,
      encodedQueueCapacity: 3,
      consecutiveEncodedQueueNearFullSamples: 2
    )
    let moderate = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0,
      encodedQueueDepth: 2,
      encodedQueueCapacity: 3,
      consecutiveEncodedQueueNearFullSamples: 3
    )
    let severe = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0,
      encodedQueueDepth: 3,
      encodedQueueCapacity: 3
    )
    let unavailable = HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0,
      encodedQueueDepth: nil,
      encodedQueueCapacity: nil
    )

    XCTAssertEqual(transientNearFull.level(maximumFramesPerSecond: 60), .none)
    XCTAssertEqual(moderate.level(maximumFramesPerSecond: 60), .moderate)
    XCTAssertEqual(severe.level(maximumFramesPerSecond: 60), .severe)
    XCTAssertEqual(unavailable.level(maximumFramesPerSecond: 60), .none)
  }

  func testCurrentRouteNetworkMetricsApplyBoundedPressureAndPreserveUnknown() {
    func network(
      delay: Int?,
      rtt: Int?,
      responseDelayedSubscribers: Int? = 0
    ) -> HostCaptureBackpressure {
      HostCaptureBackpressure(
        encodeInFlight: 0,
        latestEncodeLatencyMS: nil,
        recentSendOutcomeCount: 0,
        recentSendDropRate: 0,
        consecutiveSendDrops: 0,
        networkDelayMS: delay,
        roundTripTimeMS: rtt,
        responseDelayedSubscribers: responseDelayedSubscribers
      )
    }

    XCTAssertEqual(network(delay: nil, rtt: nil, responseDelayedSubscribers: nil)
      .level(maximumFramesPerSecond: 60), .none)
    XCTAssertEqual(network(delay: 149, rtt: 249)
      .level(maximumFramesPerSecond: 60), .none)
    XCTAssertEqual(network(delay: 150, rtt: 249)
      .level(maximumFramesPerSecond: 60), .moderate)
    XCTAssertEqual(network(delay: 149, rtt: 250)
      .level(maximumFramesPerSecond: 60), .moderate)
    XCTAssertEqual(network(delay: 300, rtt: 0)
      .level(maximumFramesPerSecond: 60), .severe)
    XCTAssertEqual(network(delay: 0, rtt: 500)
      .level(maximumFramesPerSecond: 60), .severe)
    XCTAssertEqual(network(delay: 0, rtt: 0, responseDelayedSubscribers: 1)
      .level(maximumFramesPerSecond: 60), .severe)
  }

  func testDemotionNeedsFullWindowAndDwellBeforeIdle() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 60,
      windowSize: 4,
      minimumDwellTime: 2,
      startedAtNanoseconds: 0
    )

    XCTAssertEqual(observe(&controller, ratio: 0, seconds: 0.5).framesPerSecond, 60)
    XCTAssertEqual(observe(&controller, ratio: 0, seconds: 1.0).framesPerSecond, 60)
    XCTAssertEqual(observe(&controller, ratio: 0, seconds: 1.5).framesPerSecond, 60)

    let idle = observe(&controller, ratio: 0, seconds: 2.0)
    XCTAssertEqual(idle.contentState, .idle)
    XCTAssertEqual(idle.framesPerSecond, 3)
    XCTAssertTrue(idle.dirtyMetadataTrusted)
  }

  func testMinimumDwellPreventsImmediatePromotionThenAllowsEscapeFromIdle() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 60,
      windowSize: 4,
      minimumDwellTime: 2,
      startedAtNanoseconds: 0
    )
    for index in 1...4 {
      _ = observe(&controller, ratio: 0, seconds: Double(index) * 0.5)
    }
    XCTAssertEqual(controller.decision.contentState, .idle)

    let held = observe(&controller, ratio: 0.5, seconds: 2.1)
    XCTAssertEqual(held.contentState, .idle)
    XCTAssertEqual(held.framesPerSecond, 3)

    let promoted = observe(&controller, ratio: 0.5, seconds: 4.0)
    XCTAssertEqual(promoted.contentState, .highMotion)
    XCTAssertEqual(promoted.framesPerSecond, 60)
  }

  func testHysteresisUsesLowerHoldThresholdsOnDemotion() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 60,
      windowSize: 4,
      minimumDwellTime: 0,
      startedAtNanoseconds: 0
    )

    for index in 1...4 {
      _ = observe(&controller, ratio: 0.10, seconds: Double(index))
    }
    XCTAssertEqual(controller.decision.contentState, .interactive)

    for index in 5...8 {
      _ = observe(&controller, ratio: 0.001, seconds: Double(index))
    }
    XCTAssertEqual(controller.decision.contentState, .lowMotion)

    for index in 9...12 {
      _ = observe(&controller, ratio: 0, seconds: Double(index))
    }
    XCTAssertEqual(controller.decision.contentState, .idle)
  }

  func testMissingOrInvalidDirtyMetadataFailsSafeToNegotiatedCap() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 30,
      windowSize: 2,
      minimumDwellTime: 0,
      startedAtNanoseconds: 0
    )
    _ = observe(&controller, ratio: 0, seconds: 1)
    let idle = observe(&controller, ratio: 0, seconds: 2)
    XCTAssertEqual(idle.framesPerSecond, 3)

    let unknown = controller.observe(
      dirtyAreaRatio: nil,
      nowNanoseconds: nanoseconds(2.1)
    )
    XCTAssertEqual(unknown.contentState, .highMotion)
    XCTAssertEqual(unknown.framesPerSecond, 30)
    XCTAssertFalse(unknown.dirtyMetadataTrusted)

    let invalid = controller.observe(
      dirtyAreaRatio: .nan,
      nowNanoseconds: nanoseconds(2.2)
    )
    XCTAssertEqual(invalid.framesPerSecond, 30)
    XCTAssertFalse(invalid.dirtyMetadataTrusted)
  }

  func testEveryTierIsBoundedByNegotiatedMaximum() {
    var controller = HostCaptureCadenceController(
      maximumFramesPerSecond: 15,
      windowSize: 2,
      minimumDwellTime: 0,
      startedAtNanoseconds: 0
    )
    XCTAssertEqual(controller.decision.framesPerSecond, 15)
    _ = observe(&controller, ratio: 0, seconds: 1)
    XCTAssertEqual(observe(&controller, ratio: 0, seconds: 2).framesPerSecond, 3)
    XCTAssertEqual(observe(&controller, ratio: 0.1, seconds: 3).framesPerSecond, 15)
    XCTAssertLessThanOrEqual(controller.decision.framesPerSecond, 15)
  }

  func testStreamConfigurationAppliesCadenceWithoutChangingCaptureContract() {
    let capture = HostCaptureConfiguration(
      displayIndex: 0,
      width: 1_920,
      height: 1_080,
      framesPerSecond: 30,
      showsCursor: false
    )
    let lowMotion = HostScreenCaptureAdapter.streamConfiguration(
      for: capture,
      framesPerSecond: 12
    )
    XCTAssertEqual(lowMotion.width, 1_920)
    XCTAssertEqual(lowMotion.height, 1_080)
    XCTAssertEqual(lowMotion.minimumFrameInterval, CMTime(value: 1, timescale: 12))
    XCTAssertEqual(lowMotion.queueDepth, 3)
    XCTAssertFalse(lowMotion.showsCursor)

    let bounded = HostScreenCaptureAdapter.streamConfiguration(
      for: capture,
      framesPerSecond: 60
    )
    XCTAssertEqual(bounded.minimumFrameInterval, CMTime(value: 1, timescale: 30))
  }

  private func observe(
    _ controller: inout HostCaptureCadenceController,
    ratio: Double,
    seconds: Double
  ) -> HostCaptureCadenceDecision {
    controller.observe(
      dirtyAreaRatio: ratio,
      nowNanoseconds: nanoseconds(seconds)
    )
  }

  private func environmentalPressure(
    thermalState: String?,
    lowPowerModeEnabled: Bool? = false
  ) -> HostCaptureBackpressure {
    HostCaptureBackpressure(
      encodeInFlight: 0,
      latestEncodeLatencyMS: nil,
      recentSendOutcomeCount: 0,
      recentSendDropRate: 0,
      consecutiveSendDrops: 0,
      thermalState: thermalState,
      lowPowerModeEnabled: lowPowerModeEnabled
    )
  }

  private func nanoseconds(_ seconds: Double) -> UInt64 {
    UInt64(seconds * 1_000_000_000)
  }
}
