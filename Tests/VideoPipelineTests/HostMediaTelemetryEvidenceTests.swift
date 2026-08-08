import Foundation
import XCTest

@testable import VideoPipeline

private struct HostEvidenceNoopStageRecorder: HostMediaStageRecording {
  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {}
}

final class HostMediaTelemetryEvidenceTests: XCTestCase {
  func testEvidenceUsesVersionedSanitizedAllowlist() throws {
    let telemetry = makeTelemetry()
    telemetry.markDropReasonsInstrumented([
      .captureSuperseded,
      .networkBackpressure,
    ])
    telemetry.record(.sendSubmit, presentationTimeUS: 1, byteCount: 512)
    telemetry.record(.sendDropped, presentationTimeUS: 1, byteCount: 512)
    telemetry.recordDrop(.networkBackpressure)
    telemetry.recordRawFrameQueueDepth(2)
    telemetry.recordRawFrameQueueDepth(1)
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
    XCTAssertTrue(telemetry.recordWriterTiming(
      cycles: 3,
      subscriberDispatches: 5,
      dispatchWallTotalUS: 120,
      maximumDispatchWallUS: 70,
      confirmationWaitTotalUS: 900,
      maximumConfirmationWaitUS: 400,
      completedConfirmations: 2,
      timedOutConfirmations: 1,
      finalized: true
    ))
    XCTAssertTrue(telemetry.recordNetworkMetrics(
      subscriberCount: 2,
      qosSubscriberCount: 2,
      delaySampledSubscribers: 2,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 1,
      networkDelayMS: 180,
      roundTripTimeMS: 42,
      finalized: true
    ))
    XCTAssertTrue(telemetry.recordTransportMetrics(
      subscriberCount: 2,
      directSubscribers: 1,
      relaySubscribers: 0,
      unknownSubscribers: 1,
      finalized: true
    ))
    telemetry.recordEncoderState(HostEncoderRuntimeState(
      hardwareAccelerated: true,
      softwareFallback: false,
      encoderID: "com.apple.videotoolbox.videoencoder.ave.avc"
    ))
    let evidence = HostMediaTelemetryEvidence(
      snapshot: telemetry.snapshot(),
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(evidence)
    let root = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(root["schema"] as? String, "farpane-media-telemetry")
    XCTAssertEqual(root["schemaVersion"] as? Int, 7)
    XCTAssertEqual(root["evidenceKind"] as? String, "route-stop-diagnostic-snapshot")
    XCTAssertEqual(labels(of: evidence.media), [
      "codec", "requestedWidth", "requestedHeight", "requestedFramesPerSecond",
      "captureWidth", "captureHeight", "pixelFormat", "hardwareAccelerated",
      "softwareFallback", "encoderIdentifier",
    ])
    XCTAssertEqual(labels(of: evidence.capture), [
      "callbacks", "validFrames", "actualFramesPerSecond", "latestDirtyAreaRatio",
      "averageDirtyAreaRatio", "maximumLogicalRawFrameCopyCount",
      "rawFrameQueueDepth", "maximumRawFrameQueueDepth",
    ])
    XCTAssertEqual(labels(of: evidence.cadence), [
      "contentState", "targetFramesPerSecond", "appliedFramesPerSecond",
      "dirtyMetadataTrusted", "pressureLevel", "contentTransitions",
      "pressureTransitions", "configurationUpdateAttempts",
      "configurationUpdatesApplied", "configurationUpdateFailures",
      "configurationUpdateCancellations", "configurationUpdateInFlight",
    ])
    XCTAssertEqual(labels(of: evidence.encode), [
      "submissions", "rejected", "packets", "inFlight", "maximumInFlight",
      "trackedLatencies", "latencyTrackingEvictions", "latencyP50Milliseconds",
      "latencyP95Milliseconds", "latencyP99Milliseconds", "latestLatencyMilliseconds",
      "encodedBytes", "encodedBitRateBitsPerSecond", "keyframes",
    ])
    XCTAssertEqual(labels(of: evidence.send), [
      "submissions", "accepted", "dropped", "recentOutcomeCount",
      "recentDropRate", "consecutiveDrops", "encodedQueueSamples",
      "encodedQueueDepth", "maximumEncodedQueueDepth", "encodedQueueCapacity",
      "encodedQueueFinalized",
    ])
    XCTAssertEqual(labels(of: evidence.writer), [
      "metricSamples", "cycles", "subscriberDispatches",
      "dispatchWallTotalMicroseconds", "maximumDispatchWallMicroseconds",
      "confirmationWaitTotalMicroseconds", "maximumConfirmationWaitMicroseconds",
      "completedConfirmations", "timedOutConfirmations", "finalized",
    ])
    XCTAssertEqual(labels(of: evidence.network), [
      "metricSamples", "subscriberCount", "qosSubscriberCount",
      "delaySampledSubscribers", "rttSampledSubscribers",
      "responseDelayedSubscribers", "latestNetworkDelayMilliseconds",
      "maximumNetworkDelayMilliseconds", "latestRoundTripTimeMilliseconds",
      "maximumRoundTripTimeMilliseconds", "finalized",
    ])
    XCTAssertEqual(labels(of: evidence.transport), [
      "metricSamples", "subscriberCount", "directSubscribers",
      "relaySubscribers", "unknownSubscribers", "finalized",
    ])
    XCTAssertEqual(labels(of: evidence.drops), [
      "captureSuperseded", "encoderBackpressure", "networkBackpressure",
      "reconfigure", "invalidFrame", "shutdown", "classified",
      "unclassified", "total",
    ])
    XCTAssertEqual(labels(of: evidence.drops.captureSuperseded), [
      "instrumented", "count",
    ])
    XCTAssertEqual(labels(of: evidence.process), [
      "samples", "latestCPUPercent", "peakCPUPercent", "latestResidentBytes",
      "peakResidentBytes", "latestPhysicalFootprintBytes",
      "peakPhysicalFootprintBytes", "latestThreadCount", "peakThreadCount",
      "thermalState", "powerSource", "lowPowerModeEnabled",
    ])
    XCTAssertEqual(Set(root.keys), [
      "schema", "schemaVersion", "evidenceKind", "capturedAt", "media",
      "capture", "cadence", "encode", "send", "writer", "network", "transport",
      "drops", "process", "runtimeSeconds",
    ])
    XCTAssertEqual(keys(in: root, named: "media"), [
      "codec", "requestedWidth", "requestedHeight", "requestedFramesPerSecond",
      "hardwareAccelerated", "softwareFallback", "encoderIdentifier",
    ])
    XCTAssertEqual(keys(in: root, named: "capture"), [
      "callbacks", "validFrames", "actualFramesPerSecond",
      "maximumLogicalRawFrameCopyCount", "rawFrameQueueDepth",
      "maximumRawFrameQueueDepth",
    ])
    let capture = try XCTUnwrap(root["capture"] as? [String: Any])
    XCTAssertEqual(capture["rawFrameQueueDepth"] as? Int, 1)
    XCTAssertEqual(capture["maximumRawFrameQueueDepth"] as? Int, 2)
    XCTAssertEqual(keys(in: root, named: "cadence"), [
      "contentState", "targetFramesPerSecond", "appliedFramesPerSecond",
      "dirtyMetadataTrusted", "pressureLevel", "contentTransitions",
      "pressureTransitions", "configurationUpdateAttempts",
      "configurationUpdatesApplied", "configurationUpdateFailures",
      "configurationUpdateCancellations", "configurationUpdateInFlight",
    ])
    XCTAssertEqual(keys(in: root, named: "encode"), [
      "submissions", "rejected", "packets", "inFlight", "maximumInFlight",
      "trackedLatencies", "latencyTrackingEvictions", "encodedBytes",
      "encodedBitRateBitsPerSecond", "keyframes",
    ])
    XCTAssertEqual(keys(in: root, named: "send"), [
      "submissions", "accepted", "dropped", "recentOutcomeCount",
      "recentDropRate", "consecutiveDrops", "encodedQueueSamples",
      "encodedQueueDepth", "maximumEncodedQueueDepth", "encodedQueueCapacity",
      "encodedQueueFinalized",
    ])
    let send = try XCTUnwrap(root["send"] as? [String: Any])
    XCTAssertEqual(send["encodedQueueSamples"] as? Int, 2)
    XCTAssertEqual(send["encodedQueueDepth"] as? Int, 1)
    XCTAssertEqual(send["maximumEncodedQueueDepth"] as? Int, 3)
    XCTAssertEqual(send["encodedQueueCapacity"] as? Int, 3)
    XCTAssertEqual(send["encodedQueueFinalized"] as? Bool, true)
    XCTAssertEqual(keys(in: root, named: "writer"), [
      "metricSamples", "cycles", "subscriberDispatches",
      "dispatchWallTotalMicroseconds", "maximumDispatchWallMicroseconds",
      "confirmationWaitTotalMicroseconds", "maximumConfirmationWaitMicroseconds",
      "completedConfirmations", "timedOutConfirmations", "finalized",
    ])
    let writer = try XCTUnwrap(root["writer"] as? [String: Any])
    XCTAssertEqual(writer["metricSamples"] as? Int, 1)
    XCTAssertEqual(writer["cycles"] as? Int, 3)
    XCTAssertEqual(writer["subscriberDispatches"] as? Int, 5)
    XCTAssertEqual(writer["dispatchWallTotalMicroseconds"] as? Int, 120)
    XCTAssertEqual(writer["maximumDispatchWallMicroseconds"] as? Int, 70)
    XCTAssertEqual(writer["confirmationWaitTotalMicroseconds"] as? Int, 900)
    XCTAssertEqual(writer["maximumConfirmationWaitMicroseconds"] as? Int, 400)
    XCTAssertEqual(writer["completedConfirmations"] as? Int, 2)
    XCTAssertEqual(writer["timedOutConfirmations"] as? Int, 1)
    XCTAssertEqual(writer["finalized"] as? Bool, true)
    XCTAssertEqual(keys(in: root, named: "network"), [
      "metricSamples", "subscriberCount", "qosSubscriberCount",
      "delaySampledSubscribers", "rttSampledSubscribers",
      "responseDelayedSubscribers", "latestNetworkDelayMilliseconds",
      "maximumNetworkDelayMilliseconds", "latestRoundTripTimeMilliseconds",
      "maximumRoundTripTimeMilliseconds", "finalized",
    ])
    let network = try XCTUnwrap(root["network"] as? [String: Any])
    XCTAssertEqual(network["metricSamples"] as? Int, 1)
    XCTAssertEqual(network["subscriberCount"] as? Int, 2)
    XCTAssertEqual(network["qosSubscriberCount"] as? Int, 2)
    XCTAssertEqual(network["delaySampledSubscribers"] as? Int, 2)
    XCTAssertEqual(network["rttSampledSubscribers"] as? Int, 1)
    XCTAssertEqual(network["responseDelayedSubscribers"] as? Int, 1)
    XCTAssertEqual(network["latestNetworkDelayMilliseconds"] as? Int, 180)
    XCTAssertEqual(network["maximumNetworkDelayMilliseconds"] as? Int, 180)
    XCTAssertEqual(network["latestRoundTripTimeMilliseconds"] as? Int, 42)
    XCTAssertEqual(network["maximumRoundTripTimeMilliseconds"] as? Int, 42)
    XCTAssertEqual(network["finalized"] as? Bool, true)
    XCTAssertEqual(keys(in: root, named: "transport"), [
      "metricSamples", "subscriberCount", "directSubscribers",
      "relaySubscribers", "unknownSubscribers", "finalized",
    ])
    let transport = try XCTUnwrap(root["transport"] as? [String: Any])
    XCTAssertEqual(transport["metricSamples"] as? Int, 1)
    XCTAssertEqual(transport["subscriberCount"] as? Int, 2)
    XCTAssertEqual(transport["directSubscribers"] as? Int, 1)
    XCTAssertEqual(transport["relaySubscribers"] as? Int, 0)
    XCTAssertEqual(transport["unknownSubscribers"] as? Int, 1)
    XCTAssertEqual(transport["finalized"] as? Bool, true)
    XCTAssertEqual(keys(in: root, named: "drops"), [
      "captureSuperseded", "encoderBackpressure", "networkBackpressure",
      "reconfigure", "invalidFrame", "shutdown", "classified",
      "unclassified", "total",
    ])
    let drops = try XCTUnwrap(root["drops"] as? [String: Any])
    let captureSuperseded = try XCTUnwrap(
      drops["captureSuperseded"] as? [String: Any]
    )
    XCTAssertEqual(captureSuperseded["instrumented"] as? Bool, true)
    XCTAssertEqual(captureSuperseded["count"] as? Int, 0)
    let networkBackpressure = try XCTUnwrap(
      drops["networkBackpressure"] as? [String: Any]
    )
    XCTAssertEqual(networkBackpressure["instrumented"] as? Bool, true)
    XCTAssertEqual(networkBackpressure["count"] as? Int, 1)
    XCTAssertEqual(drops["classified"] as? Int, 1)
    XCTAssertEqual(drops["unclassified"] as? Int, 0)
    XCTAssertEqual(drops["total"] as? Int, 1)
    XCTAssertEqual(keys(in: root, named: "process"), [
      "samples", "peakCPUPercent", "peakResidentBytes",
      "peakPhysicalFootprintBytes", "peakThreadCount",
    ])

    let json = try XCTUnwrap(String(data: data, encoding: .utf8))
    for forbidden in [
      "displayIndex", "peer", "connection", "server", "password",
      "publicKey", "credential", "payload", "outputURL", "pid",
    ] {
      XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden))
    }
  }

  func testWriterIsExplicitAtomicAndRefusesOverwrite() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try HostMediaTelemetryEvidenceWriter(outputURL: fixture.output)
    try writer.write(
      snapshot: makeTelemetry().snapshot(),
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let original = try Data(contentsOf: fixture.output)
    XCTAssertFalse(original.isEmpty)

    XCTAssertThrowsError(try writer.write(snapshot: makeTelemetry().snapshot())) { error in
      XCTAssertEqual(
        error as? HostMediaTelemetryEvidenceError,
        .outputAlreadyExists
      )
    }
    XCTAssertEqual(try Data(contentsOf: fixture.output), original)
  }

  func testEnvironmentConfigurationDefaultsOffAndRejectsAmbiguousPaths() throws {
    XCTAssertNil(try HostMediaTelemetryEvidenceWriter.configured(environment: [:]))
    XCTAssertThrowsError(try HostMediaTelemetryEvidenceWriter.configured(
      environment: [HostMediaTelemetryEvidenceWriter.outputEnvironmentKey: "relative.json"]
    )) { error in
      XCTAssertEqual(
        error as? HostMediaTelemetryEvidenceError,
        .outputPathMustBeAbsolute
      )
    }
    XCTAssertThrowsError(try HostMediaTelemetryEvidenceWriter.configured(
      environment: [HostMediaTelemetryEvidenceWriter.outputEnvironmentKey: "/tmp/evidence.txt"]
    )) { error in
      XCTAssertEqual(
        error as? HostMediaTelemetryEvidenceError,
        .outputMustBeJSON
      )
    }
  }

  private func makeTelemetry() -> HostMediaTelemetry {
    HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 7,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostEvidenceNoopStageRecorder()
    )
  }

  private func keys(in root: [String: Any], named name: String) -> Set<String> {
    Set((root[name] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
  }

  private func labels<T>(of value: T) -> Set<String> {
    Set(Mirror(reflecting: value).children.compactMap(\.label))
  }

  private func makeFixture() throws -> (directory: URL, output: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("farpane-host-evidence-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, directory.appendingPathComponent("route.json"))
  }
}
