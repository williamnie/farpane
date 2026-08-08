import Foundation
import XCTest

@testable import VideoPipeline

private struct HostMediaLiveLogNoopRecorder: HostMediaStageRecording {
  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {}
}

final class HostMediaTelemetryLiveLogTests: XCTestCase {
  func testWriterPersistsSanitizedLifecycleAndThrottledPeriodicSamples() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try HostMediaTelemetryLiveLogWriter(
      outputURL: fixture.output,
      maximumPeriodicRecords: 2
    )
    let snapshot = makeSnapshot()

    XCTAssertTrue(try writer.record(
      snapshot: snapshot,
      event: .routeStarted,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicNanoseconds: 1_000_000_000
    ))
    XCTAssertTrue(try writer.record(
      snapshot: snapshot,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000.1),
      monotonicNanoseconds: 1_100_000_000
    ))
    XCTAssertFalse(try writer.record(
      snapshot: snapshot,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
      monotonicNanoseconds: 1_500_000_000
    ))
    XCTAssertTrue(try writer.record(
      snapshot: snapshot,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_001.1),
      monotonicNanoseconds: 2_100_000_000
    ))
    XCTAssertFalse(try writer.record(
      snapshot: snapshot,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_002.2),
      monotonicNanoseconds: 3_200_000_000
    ))
    XCTAssertTrue(try writer.record(
      snapshot: snapshot,
      event: .routeStopped,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_001.2),
      monotonicNanoseconds: 2_200_000_000
    ))

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 4)
    XCTAssertEqual(records.map { $0["sequence"] as? Int }, [1, 2, 3, 4])
    XCTAssertEqual(records.map { $0["event"] as? String }, [
      "routeStarted", "periodic", "periodic", "routeStopped",
    ])
    XCTAssertEqual(records[1]["schema"] as? String, "farpane-host-media-live")
    XCTAssertEqual(records[1]["schemaVersion"] as? Int, 2)
    XCTAssertEqual(records[1]["recentWindowSeconds"] as? Int, 5)
    XCTAssertEqual(records[1]["codec"] as? String, "h264")
    XCTAssertEqual(records[1]["requestedFPS"] as? Int, 30)
    XCTAssertEqual(records[1]["captureTargetFPS"] as? Int, 15)
    XCTAssertEqual(records[1]["captureAppliedFPS"] as? Int, 15)
    XCTAssertEqual(records[1]["captureContentState"] as? String, "highMotion")
    XCTAssertEqual(records[1]["captureCallbackCount"] as? Int, 3)
    XCTAssertEqual(
      records[1]["captureFrameStatusCounts"] as? [String: Int],
      [
        "complete": 2, "idle": 1, "blank": 0, "suspended": 0,
        "started": 0, "stopped": 0, "missingOrInvalid": 0, "unknown": 0,
      ]
    )
    XCTAssertEqual(
      records[1]["captureCompleteDirtyRectsCounts"] as? [String: Int],
      [
        "absent": 1, "unrecognized": 0,
        "recognizedEmpty": 1, "recognizedNonEmpty": 0,
      ]
    )
    XCTAssertEqual(records[1]["captureAppliedPressureLevel"] as? String, "moderate")
    XCTAssertEqual(records[1]["captureObservedPressureLevel"] as? String, "moderate")
    XCTAssertEqual(records[1]["capturePressureCauses"] as? [String], ["networkDelay"])
    XCTAssertEqual(records[1]["networkDelayMS"] as? Int, 180)
    XCTAssertTrue(Set(records[1].keys).isSubset(of: expectedKeys))

    let contents = try String(contentsOf: fixture.output, encoding: .utf8)
    for forbidden in [
      "localId", "instanceId", "peer", "connectionId", "server",
      "password", "publicKey", "credential", "payload", "displayId",
      "outputURL",
    ] {
      XCTAssertFalse(contents.localizedCaseInsensitiveContains(forbidden))
    }
  }

  func testWriterRejectsUnsafeOrExistingOutput() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    XCTAssertThrowsError(try HostMediaTelemetryLiveLogWriter(
      outputURL: try XCTUnwrap(URL(string: "relative.jsonl"))
    )) { error in
      XCTAssertEqual(error as? HostMediaLiveLogError, .outputPathMustBeAbsolute)
    }
    XCTAssertThrowsError(try HostMediaTelemetryLiveLogWriter(
      outputURL: fixture.output.deletingPathExtension().appendingPathExtension("json")
    )) { error in
      XCTAssertEqual(error as? HostMediaLiveLogError, .outputMustBeJSONLines)
    }
    XCTAssertThrowsError(try HostMediaTelemetryLiveLogWriter(
      outputURL: fixture.output,
      maximumPeriodicRecords: 0
    )) { error in
      XCTAssertEqual(error as? HostMediaLiveLogError, .invalidMaximumPeriodicRecords)
    }
    _ = try HostMediaTelemetryLiveLogWriter(outputURL: fixture.output)
    XCTAssertThrowsError(try HostMediaTelemetryLiveLogWriter(outputURL: fixture.output)) { error in
      XCTAssertEqual(error as? HostMediaLiveLogError, .outputAlreadyExists)
    }
  }

  private var expectedKeys: Set<String> {
    [
      "schema", "schemaVersion", "sequence", "capturedAt",
      "monotonicNanoseconds", "event", "recentWindowSeconds", "codec",
      "requestedFPS", "recentCaptureFPS", "recentEncodedFPS",
      "recentRustAdmissionFPS", "captureAverageFPS", "captureTargetFPS",
      "captureAppliedFPS", "captureContentState", "captureDirtyMetadataTrusted",
      "captureCallbackCount", "captureFrameStatusCounts",
      "captureCompleteDirtyRectsCounts",
      "latestDirtyAreaRatio", "captureAppliedPressureLevel",
      "captureObservedPressureLevel", "capturePressureCauses",
      "captureConfigurationUpdateInFlight", "encodeInFlight",
      "latestEncodeLatencyMS", "recentSendOutcomeCount", "recentSendDropRate",
      "consecutiveSendDrops", "encodedQueueDepth", "encodedQueueCapacity",
      "networkDelayMS", "roundTripTimeMS", "responseDelayedSubscribers",
      "processCPUPercent", "residentBytes", "physicalFootprintBytes",
      "thermalState", "powerSource", "lowPowerModeEnabled", "runtimeSeconds",
    ]
  }

  private func makeSnapshot() -> HostMediaTelemetrySnapshot {
    let telemetry = HostMediaTelemetry(
      configuration: HostMediaPipelineConfiguration(
        codec: .h264,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      ),
      stageRecorder: HostMediaLiveLogNoopRecorder()
    )
    telemetry.recordCaptureCadence(.decision(HostCaptureCadenceDecision(
      contentState: .highMotion,
      framesPerSecond: 15,
      dirtyMetadataTrusted: false,
      pressureLevel: .moderate
    )))
    telemetry.recordCaptureCadence(.configurationApplied(framesPerSecond: 15))
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .complete,
      completeFrameDirtyRects: .absent
    ))
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .complete,
      completeFrameDirtyRects: .recognizedEmpty
    ))
    telemetry.recordCaptureSample(HostCaptureSampleMetadataAvailability(
      frameStatus: .idle,
      completeFrameDirtyRects: nil
    ))
    XCTAssertTrue(telemetry.recordNetworkMetrics(
      subscriberCount: 1,
      qosSubscriberCount: 1,
      delaySampledSubscribers: 1,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 0,
      networkDelayMS: 180,
      roundTripTimeMS: 80,
      finalized: false
    ))
    return telemetry.snapshot()
  }

  private func readRecords(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { line in
        try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
      }
  }

  private func makeFixture() -> (directory: URL, output: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("farpane-host-media-live-log-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, directory.appendingPathComponent("host-media.jsonl"))
  }
}
