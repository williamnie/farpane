import XCTest

@testable import VideoPipeline

private struct HostMediaNoopStageRecorder: HostMediaStageRecording {
  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {}
}

final class HostMediaTelemetryTests: XCTestCase {
  func testTracksSanitizedCaptureMetadataAvailabilityAtomically() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .complete,
      completeFrameDirtyRects: .absent
    ))
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .complete,
      completeFrameDirtyRects: .recognizedNonEmpty
    ))
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .idle,
      completeFrameDirtyRects: nil
    ))
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .missingOrInvalid,
      completeFrameDirtyRects: nil
    ))

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.captureCallbacks, 4)
    XCTAssertEqual(snapshot.captureFrameStatusCounts, HostCaptureFrameStatusCounts(
      complete: 2,
      idle: 1,
      blank: 0,
      suspended: 0,
      started: 0,
      stopped: 0,
      missingOrInvalid: 1,
      unknown: 0
    ))
    XCTAssertEqual(snapshot.captureFrameStatusCounts.total, snapshot.captureCallbacks)
    XCTAssertEqual(
      snapshot.captureCompleteDirtyRectsCounts,
      HostCaptureDirtyRectsAttachmentCounts(
        absent: 1,
        unrecognized: 0,
        recognizedEmpty: 0,
        recognizedNonEmpty: 1
      )
    )
    XCTAssertEqual(
      snapshot.captureCompleteDirtyRectsCounts.total,
      snapshot.captureFrameStatusCounts.complete
    )
  }

  func testReportsRecentCaptureRateAndDecaysAfterFiveSecondWindow() throws {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 16,
        height: 16,
        framesPerSecond: 30,
        bitRate: 1_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )
    let frame = try makeCapturedFrame()
    let base = DispatchTime.now().uptimeNanoseconds
    for index in 0...30 {
      telemetry.recordCapturedFrame(
        frame,
        nowNS: base + UInt64(index) * 1_000_000_000 / 30
      )
    }

    let active = telemetry.snapshot(nowNS: base + 1_000_000_000)
    XCTAssertEqual(active.actualFPS, 30, accuracy: 0.000_001)
    XCTAssertEqual(active.recentCaptureFPS, 30, accuracy: 0.000_001)

    let stale = telemetry.snapshot(nowNS: base + 7_000_000_000)
    XCTAssertEqual(stale.actualFPS, 30, accuracy: 0.000_001)
    XCTAssertEqual(stale.recentCaptureFPS, 0, accuracy: 0.000_001)
  }

  func testReportsDistinctRecentCaptureEncodeAndRustAdmissionRates() throws {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 16,
        height: 16,
        framesPerSecond: 30,
        bitRate: 1_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )
    let frame = try makeCapturedFrame()
    let base = DispatchTime.now().uptimeNanoseconds
    for index in 0...30 {
      telemetry.recordCapturedFrame(
        frame,
        nowNS: base + UInt64(index) * 1_000_000_000 / 30
      )
    }
    for index in 0...25 {
      telemetry.recordPacket(
        presentationTimeUS: UInt64(index),
        byteCount: 1_024,
        isKeyframe: index == 0,
        nowNS: base + UInt64(index) * 1_000_000_000 / 25
      )
    }
    for index in 0...20 {
      telemetry.record(
        .sendAccepted,
        presentationTimeUS: UInt64(index),
        byteCount: 1_024,
        nowNS: base + UInt64(index) * 1_000_000_000 / 20
      )
    }

    let active = telemetry.snapshot(nowNS: base + 1_000_000_000)
    XCTAssertEqual(active.recentCaptureFPS, 30, accuracy: 0.000_001)
    XCTAssertEqual(active.recentEncodedFPS, 25, accuracy: 0.000_001)
    XCTAssertEqual(active.recentSendAcceptedFPS, 20, accuracy: 0.000_001)

    let stale = telemetry.snapshot(nowNS: base + 7_000_000_000)
    XCTAssertEqual(stale.recentCaptureFPS, 0, accuracy: 0.000_001)
    XCTAssertEqual(stale.recentEncodedFPS, 0, accuracy: 0.000_001)
    XCTAssertEqual(stale.recentSendAcceptedFPS, 0, accuracy: 0.000_001)
  }

  func testClassifiesInstrumentedDropsAndKeepsUnavailableReasonsUnknown() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )
    telemetry.markDropReasonsInstrumented([
      .encoderBackpressure,
      .networkBackpressure,
      .reconfigure,
      .invalidFrame,
      .shutdown,
    ])
    telemetry.record(.encodeSubmit, presentationTimeUS: 7, byteCount: 0)
    telemetry.recordEncoderDrop(
      presentationTimeUS: 7,
      reason: .encoderBackpressure
    )
    telemetry.recordDrop(.networkBackpressure)
    telemetry.recordDrop(.reconfigure)
    telemetry.recordDrop(.invalidFrame)
    telemetry.recordDrop(.shutdown)
    telemetry.recordUnclassifiedDrop()
    telemetry.recordRawFrameQueueDepth(2)
    telemetry.recordRawFrameQueueDepth(1)

    let snapshot = telemetry.snapshot()
    XCTAssertNil(snapshot.drops.captureSuperseded)
    XCTAssertEqual(snapshot.drops.encoderBackpressure, 1)
    XCTAssertEqual(snapshot.drops.networkBackpressure, 1)
    XCTAssertEqual(snapshot.drops.reconfigure, 1)
    XCTAssertEqual(snapshot.drops.invalidFrame, 1)
    XCTAssertEqual(snapshot.drops.shutdown, 1)
    XCTAssertEqual(snapshot.drops.classified, 5)
    XCTAssertEqual(snapshot.drops.unclassified, 1)
    XCTAssertEqual(snapshot.drops.total, 6)
    XCTAssertEqual(snapshot.encodeInFlight, 0)
    XCTAssertEqual(snapshot.trackedEncodeLatencies, 0)
    XCTAssertEqual(snapshot.rawFrameQueueDepth, 1)
    XCTAssertEqual(snapshot.maximumRawFrameQueueDepth, 2)
  }

  func testTracksEverySendOutcomeInsideTheFiveSecondWindow() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    for index in 0..<40 {
      telemetry.record(.sendSubmit, presentationTimeUS: UInt64(index), byteCount: 1)
      telemetry.record(
        index.isMultiple(of: 4) ? .sendDropped : .sendAccepted,
        presentationTimeUS: UInt64(index),
        byteCount: 1
      )
    }

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.recentSendOutcomeCount, 40)
    XCTAssertEqual(snapshot.recentSendDropRate, 0.25, accuracy: 0.000_001)
    XCTAssertEqual(snapshot.consecutiveSendDrops, 0)
    XCTAssertEqual(telemetry.captureBackpressure().recentSendOutcomeCount, 40)
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .severe
    )
  }

  func testBoundsRecentSendOutcomeStorageAtMaximumFiveSecondRate() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 240,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    for index in 0..<1_300 {
      telemetry.record(
        index.isMultiple(of: 2) ? .sendDropped : .sendAccepted,
        presentationTimeUS: UInt64(index),
        byteCount: 1,
        nowNS: 1_000_000_000
      )
    }

    let pressure = telemetry.captureBackpressure(nowNS: 1_000_000_000)
    XCTAssertEqual(pressure.recentSendOutcomeCount, 1_202)
    XCTAssertEqual(pressure.recentSendDropRate, 0.5, accuracy: 0.000_001)
  }

  func testSendDropPressureExpiresOutsideTheFiveSecondWindow() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    for index in 0..<8 {
      telemetry.record(
        .sendDropped,
        presentationTimeUS: UInt64(index),
        byteCount: 1,
        nowNS: UInt64(index + 1) * 100_000_000
      )
    }
    XCTAssertEqual(
      telemetry.captureBackpressure(nowNS: 1_000_000_000).recentSendOutcomeCount,
      8
    )

    let expired = telemetry.captureBackpressure(nowNS: 6_000_000_001)
    XCTAssertEqual(expired.recentSendOutcomeCount, 0)
    XCTAssertEqual(expired.recentSendDropRate, 0)
    XCTAssertEqual(expired.consecutiveSendDrops, 0)
    XCTAssertEqual(expired.level(maximumFramesPerSecond: 30), .none)
  }

  func testTracksCadenceDecisionApplyFailureAndCancellationWithoutRawData() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    telemetry.recordCaptureCadence(.decision(HostCaptureCadenceDecision(
      contentState: .idle,
      framesPerSecond: 3,
      dirtyMetadataTrusted: true,
      pressureLevel: .moderate
    )))
    telemetry.recordCaptureCadence(.decision(HostCaptureCadenceDecision(
      contentState: .idle,
      framesPerSecond: 3,
      dirtyMetadataTrusted: true,
      pressureLevel: .moderate
    )))
    telemetry.recordCaptureCadence(.configurationSubmitted(framesPerSecond: 3))
    telemetry.recordCaptureCadence(.configurationFailed(framesPerSecond: 3))
    telemetry.recordCaptureCadence(.decision(HostCaptureCadenceDecision(
      contentState: .lowMotion,
      framesPerSecond: 12,
      dirtyMetadataTrusted: true
    )))
    telemetry.recordCaptureCadence(.configurationSubmitted(framesPerSecond: 12))
    telemetry.recordCaptureCadence(.configurationApplied(framesPerSecond: 12))
    telemetry.recordCaptureCadence(.configurationSubmitted(framesPerSecond: 30))
    telemetry.recordCaptureCadence(.configurationCancelled)

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.captureContentState, .lowMotion)
    XCTAssertEqual(snapshot.captureTargetFPS, 30)
    XCTAssertEqual(snapshot.captureAppliedFPS, 12)
    XCTAssertTrue(snapshot.captureDirtyMetadataTrusted)
    XCTAssertEqual(snapshot.capturePressureLevel, .none)
    XCTAssertEqual(snapshot.captureCadenceTransitions, 2)
    XCTAssertEqual(snapshot.capturePressureTransitions, 2)
    XCTAssertEqual(snapshot.captureConfigurationUpdateAttempts, 3)
    XCTAssertEqual(snapshot.captureConfigurationUpdatesApplied, 1)
    XCTAssertEqual(snapshot.captureConfigurationUpdateFailures, 1)
    XCTAssertEqual(snapshot.captureConfigurationUpdateCancellations, 1)
    XCTAssertFalse(snapshot.captureConfigurationUpdateInFlight)
  }

  func testTracksRustQueueSubmissionOutcomesWithoutPayloadData() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    telemetry.record(.sendSubmit, presentationTimeUS: 1, byteCount: 1_024)
    telemetry.record(.sendAccepted, presentationTimeUS: 1, byteCount: 1_024)
    telemetry.record(.sendSubmit, presentationTimeUS: 2, byteCount: 512)
    telemetry.record(.sendDropped, presentationTimeUS: 2, byteCount: 512)
    telemetry.record(.encodeSubmit, presentationTimeUS: 3, byteCount: 0)
    telemetry.record(.encodeRejected, presentationTimeUS: 3, byteCount: 0)

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.sendSubmissions, 2)
    XCTAssertEqual(snapshot.sendAccepted, 1)
    XCTAssertEqual(snapshot.sendDropped, 1)
    XCTAssertEqual(snapshot.encodeSubmissions, 1)
    XCTAssertEqual(snapshot.encodeRejected, 1)
    XCTAssertEqual(snapshot.encodeInFlight, 0)
    XCTAssertEqual(snapshot.encodedBytes, 0)
    XCTAssertNil(snapshot.encoderID)
  }

  func testTracksOnlyBoundedConsistentRustEncodedQueueSamples() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    XCTAssertTrue(telemetry.recordEncodedQueueDepth(
      current: 2,
      maximum: 2,
      capacity: 3,
      finalized: false
    ))
    XCTAssertTrue(telemetry.recordEncodedQueueDepth(
      current: 1,
      maximum: 3,
      capacity: 3,
      finalized: true
    ))
    XCTAssertFalse(telemetry.recordEncodedQueueDepth(
      current: 4,
      maximum: 3,
      capacity: 3,
      finalized: false
    ))
    XCTAssertFalse(telemetry.recordEncodedQueueDepth(
      current: 0,
      maximum: 0,
      capacity: 4,
      finalized: false
    ))

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.encodedQueueSamples, 2)
    XCTAssertEqual(snapshot.encodedQueueDepth, 1)
    XCTAssertEqual(snapshot.maximumEncodedQueueDepth, 3)
    XCTAssertEqual(snapshot.encodedQueueCapacity, 3)
    XCTAssertTrue(snapshot.encodedQueueFinalized)
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .none
    )
  }

  func testFeedsValidatedRustEncodedQueueDepthIntoCapturePressure() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .none
    )
    XCTAssertTrue(telemetry.recordEncodedQueueDepth(
      current: 2,
      maximum: 2,
      capacity: 3,
      finalized: false
    ))
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .none
    )
    XCTAssertTrue(telemetry.recordEncodedQueueDepth(
      current: 2,
      maximum: 2,
      capacity: 3,
      finalized: false
    ))
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .none
    )
    XCTAssertTrue(telemetry.recordEncodedQueueDepth(
      current: 2,
      maximum: 2,
      capacity: 3,
      finalized: false
    ))
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .moderate
    )
    XCTAssertTrue(telemetry.recordEncodedQueueDepth(
      current: 3,
      maximum: 3,
      capacity: 3,
      finalized: false
    ))
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 30),
      .severe
    )
  }

  func testTracksOnlyMonotonicConsistentRustWriterTimingSamples() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    XCTAssertTrue(telemetry.recordWriterTiming(
      cycles: 2,
      subscriberDispatches: 3,
      dispatchWallTotalUS: 80,
      maximumDispatchWallUS: 50,
      confirmationWaitTotalUS: 600,
      maximumConfirmationWaitUS: 350,
      completedConfirmations: 2,
      timedOutConfirmations: 0,
      finalized: false
    ))
    XCTAssertFalse(telemetry.recordWriterTiming(
      cycles: 1,
      subscriberDispatches: 3,
      dispatchWallTotalUS: 80,
      maximumDispatchWallUS: 50,
      confirmationWaitTotalUS: 600,
      maximumConfirmationWaitUS: 350,
      completedConfirmations: 1,
      timedOutConfirmations: 0,
      finalized: false
    ))
    XCTAssertTrue(telemetry.recordWriterTiming(
      cycles: 3,
      subscriberDispatches: 5,
      dispatchWallTotalUS: 120,
      maximumDispatchWallUS: 50,
      confirmationWaitTotalUS: 1_000,
      maximumConfirmationWaitUS: 400,
      completedConfirmations: 2,
      timedOutConfirmations: 1,
      finalized: true
    ))
    XCTAssertFalse(telemetry.recordWriterTiming(
      cycles: 4,
      subscriberDispatches: 6,
      dispatchWallTotalUS: 140,
      maximumDispatchWallUS: 50,
      confirmationWaitTotalUS: 1_100,
      maximumConfirmationWaitUS: 400,
      completedConfirmations: 3,
      timedOutConfirmations: 1,
      finalized: false
    ))

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.writerMetricSamples, 2)
    XCTAssertEqual(snapshot.writerCycles, 3)
    XCTAssertEqual(snapshot.subscriberDispatches, 5)
    XCTAssertEqual(snapshot.dispatchWallTotalUS, 120)
    XCTAssertEqual(snapshot.maximumDispatchWallUS, 50)
    XCTAssertEqual(snapshot.confirmationWaitTotalUS, 1_000)
    XCTAssertEqual(snapshot.maximumConfirmationWaitUS, 400)
    XCTAssertEqual(snapshot.completedConfirmations, 2)
    XCTAssertEqual(snapshot.timedOutConfirmations, 1)
    XCTAssertTrue(snapshot.writerTimingFinalized)
  }

  func testTracksOnlyConsistentRouteNetworkSamplesAndFinalization() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    XCTAssertTrue(telemetry.recordNetworkMetrics(
      subscriberCount: 2,
      qosSubscriberCount: 2,
      delaySampledSubscribers: 1,
      rttSampledSubscribers: 0,
      responseDelayedSubscribers: 0,
      networkDelayMS: 120,
      roundTripTimeMS: nil,
      finalized: false
    ))
    XCTAssertFalse(telemetry.recordNetworkMetrics(
      subscriberCount: 1,
      qosSubscriberCount: 2,
      delaySampledSubscribers: 1,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 0,
      networkDelayMS: 80,
      roundTripTimeMS: 20,
      finalized: false
    ))
    XCTAssertTrue(telemetry.recordNetworkMetrics(
      subscriberCount: 2,
      qosSubscriberCount: 2,
      delaySampledSubscribers: 2,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 1,
      networkDelayMS: 90,
      roundTripTimeMS: 35,
      finalized: true
    ))
    XCTAssertFalse(telemetry.recordNetworkMetrics(
      subscriberCount: 2,
      qosSubscriberCount: 2,
      delaySampledSubscribers: 2,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 0,
      networkDelayMS: 70,
      roundTripTimeMS: 30,
      finalized: false
    ))

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.networkMetricSamples, 2)
    XCTAssertEqual(snapshot.networkSubscriberCount, 2)
    XCTAssertEqual(snapshot.qosSubscriberCount, 2)
    XCTAssertEqual(snapshot.delaySampledSubscribers, 2)
    XCTAssertEqual(snapshot.rttSampledSubscribers, 1)
    XCTAssertEqual(snapshot.responseDelayedSubscribers, 1)
    XCTAssertEqual(snapshot.networkDelayMS, 90)
    XCTAssertEqual(snapshot.maximumNetworkDelayMS, 120)
    XCTAssertEqual(snapshot.roundTripTimeMS, 35)
    XCTAssertEqual(snapshot.maximumRoundTripTimeMS, 35)
    XCTAssertTrue(snapshot.networkMetricsFinalized)
  }

  func testTracksOnlyCompleteTransportPartitionsAndFinalization() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    XCTAssertTrue(telemetry.recordTransportMetrics(
      subscriberCount: 3,
      directSubscribers: 1,
      relaySubscribers: 1,
      unknownSubscribers: 1,
      finalized: false
    ))
    XCTAssertFalse(telemetry.recordTransportMetrics(
      subscriberCount: 3,
      directSubscribers: 1,
      relaySubscribers: 1,
      unknownSubscribers: 0,
      finalized: false
    ))
    XCTAssertTrue(telemetry.recordTransportMetrics(
      subscriberCount: 2,
      directSubscribers: 2,
      relaySubscribers: 0,
      unknownSubscribers: 0,
      finalized: true
    ))
    XCTAssertFalse(telemetry.recordTransportMetrics(
      subscriberCount: 1,
      directSubscribers: 0,
      relaySubscribers: 1,
      unknownSubscribers: 0,
      finalized: false
    ))

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.transportMetricSamples, 2)
    XCTAssertEqual(snapshot.transportSubscriberCount, 2)
    XCTAssertEqual(snapshot.directSubscribers, 2)
    XCTAssertEqual(snapshot.relaySubscribers, 0)
    XCTAssertEqual(snapshot.unknownSubscribers, 0)
    XCTAssertTrue(snapshot.transportMetricsFinalized)
  }

  func testCapturePressureUsesLatestNetworkSampleInsteadOfRouteMaximum() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 60,
        bitRate: 8_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    XCTAssertTrue(telemetry.recordNetworkMetrics(
      subscriberCount: 1,
      qosSubscriberCount: 1,
      delaySampledSubscribers: 1,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 0,
      networkDelayMS: 350,
      roundTripTimeMS: 550,
      finalized: false
    ))
    let pressured = telemetry.snapshot()
    XCTAssertEqual(pressured.captureObservedPressureLevel, .severe)
    XCTAssertEqual(pressured.capturePressureCauses, [
      .networkDelay,
      .roundTripTime,
    ])
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 60),
      .severe
    )
    XCTAssertTrue(telemetry.recordNetworkMetrics(
      subscriberCount: 1,
      qosSubscriberCount: 1,
      delaySampledSubscribers: 1,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 0,
      networkDelayMS: 80,
      roundTripTimeMS: 100,
      finalized: true
    ))

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.captureObservedPressureLevel, .none)
    XCTAssertEqual(snapshot.capturePressureCauses, [])
    XCTAssertEqual(snapshot.maximumNetworkDelayMS, 350)
    XCTAssertEqual(snapshot.maximumRoundTripTimeMS, 550)
    XCTAssertEqual(
      telemetry.captureBackpressure().level(maximumFramesPerSecond: 60),
      .none
    )
  }

  func testBoundsEncodeLatencyCorrelationState() {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 60,
        bitRate: 8_000_000
      ),
      stageRecorder: HostMediaNoopStageRecorder()
    )

    for pts in 0..<513 {
      telemetry.record(
        .encodeSubmit,
        presentationTimeUS: UInt64(pts),
        byteCount: 0
      )
    }

    let snapshot = telemetry.snapshot()
    XCTAssertEqual(snapshot.encodeSubmissions, 513)
    XCTAssertEqual(snapshot.encodeInFlight, 513)
    XCTAssertEqual(snapshot.trackedEncodeLatencies, 512)
    XCTAssertEqual(snapshot.encodeLatencyTrackingEvictions, 1)
  }

  private func makeCapturedFrame() throws -> HostCapturedFrame {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      16,
      16,
      kCVPixelFormatType_32BGRA,
      nil,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw NSError(domain: "HostMediaTelemetryTests", code: Int(status))
    }
    return HostCapturedFrame(
      pixelBuffer: pixelBuffer,
      presentationTime: .zero,
      pixelPath: .bgraPixelTransfer,
      dirtyRectCount: 1,
      dirtyAreaRatio: 1
    )
  }
}
