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
      event: .captureSuspended,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_001.15),
      monotonicNanoseconds: 2_150_000_000
    ))
    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 4)
    XCTAssertEqual(records.map { $0["sequence"] as? Int }, [1, 2, 3, 4])
    XCTAssertEqual(records.map { $0["event"] as? String }, [
      "routeStarted", "periodic", "periodic", "captureSuspended",
    ])
    XCTAssertEqual(records[1]["schema"] as? String, "farpane-host-media-live")
    XCTAssertEqual(records[1]["schemaVersion"] as? Int, 3)
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

  func testDefaultWriterRetainsOnlyRecentOwnedProductLogs() throws {
    let fixture = makeFixture()
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(at: fixture.directory) }
    try fileManager.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: true
    )
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let stale = try makeProductLog(
      index: 1,
      in: fixture.directory,
      modifiedAt: capturedAt.addingTimeInterval(-8 * 24 * 60 * 60)
    )
    let oldestRecent = try makeProductLog(
      index: 2,
      in: fixture.directory,
      modifiedAt: capturedAt.addingTimeInterval(-400)
    )
    let secondOldestRecent = try makeProductLog(
      index: 3,
      in: fixture.directory,
      modifiedAt: capturedAt.addingTimeInterval(-300)
    )
    let retainedRecent = try makeProductLog(
      index: 4,
      in: fixture.directory,
      modifiedAt: capturedAt.addingTimeInterval(-200)
    )
    let newestRecent = try makeProductLog(
      index: 5,
      in: fixture.directory,
      modifiedAt: capturedAt.addingTimeInterval(-100)
    )
    let unrelated = fixture.directory.appendingPathComponent("operator-notes.jsonl")
    try Data("keep".utf8).write(to: unrelated)
    let symlink = productLogURL(index: 6, in: fixture.directory)
    try fileManager.createSymbolicLink(
      at: symlink,
      withDestinationURL: unrelated
    )
    let hardLink = productLogURL(index: 7, in: fixture.directory)
    try fileManager.linkItem(at: unrelated, to: hardLink)
    let matchingDirectory = productLogURL(index: 8, in: fixture.directory)
    try fileManager.createDirectory(
      at: matchingDirectory,
      withIntermediateDirectories: false
    )

    let writer = try HostMediaTelemetryLiveLogWriter.makeDefault(
      in: fixture.directory,
      capturedAt: capturedAt,
      maximumRetainedFiles: 3,
      maximumRetentionAge: 7 * 24 * 60 * 60,
      fileManager: fileManager
    )

    XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
    XCTAssertFalse(fileManager.fileExists(atPath: oldestRecent.path))
    XCTAssertFalse(fileManager.fileExists(atPath: secondOldestRecent.path))
    XCTAssertTrue(fileManager.fileExists(atPath: retainedRecent.path))
    XCTAssertTrue(fileManager.fileExists(atPath: newestRecent.path))
    XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
    XCTAssertNotNil(try? fileManager.destinationOfSymbolicLink(atPath: symlink.path))
    XCTAssertTrue(fileManager.fileExists(atPath: hardLink.path))
    XCTAssertTrue(fileManager.fileExists(atPath: matchingDirectory.path))
    XCTAssertTrue(fileManager.fileExists(atPath: writer.outputURL.path))
  }

  func testDefaultWriterFailsClosedWhenRetentionCannotDelete() throws {
    let fixture = makeFixture()
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(at: fixture.directory) }
    try fileManager.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: true
    )
    let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let existing = try makeProductLog(
      index: 1,
      in: fixture.directory,
      modifiedAt: capturedAt.addingTimeInterval(-100)
    )

    XCTAssertThrowsError(try HostMediaTelemetryLiveLogWriter.makeDefault(
      in: fixture.directory,
      capturedAt: capturedAt,
      maximumRetainedFiles: 1,
      maximumRetentionAge: 7 * 24 * 60 * 60,
      retentionRemoval: { _ in
        throw HostMediaLiveLogRemovalFailure.denied
      }
    )) { error in
      XCTAssertEqual(error as? HostMediaLiveLogError, .retentionFailed)
    }
    XCTAssertTrue(fileManager.fileExists(atPath: existing.path))
    XCTAssertEqual(
      try fileManager.contentsOfDirectory(atPath: fixture.directory.path).count,
      1
    )
  }

  func testDefaultWriterRejectsInvalidRetentionPolicy() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    XCTAssertEqual(HostMediaTelemetryLiveLogWriter.maximumRetainedLogFiles, 24)
    XCTAssertEqual(
      HostMediaTelemetryLiveLogWriter.maximumRetentionAge,
      7 * 24 * 60 * 60
    )

    for (maximumFiles, maximumAge) in [(0, 60.0), (1, 0.0), (1, .nan)] {
      XCTAssertThrowsError(try HostMediaTelemetryLiveLogWriter.makeDefault(
        in: fixture.directory,
        maximumRetainedFiles: maximumFiles,
        maximumRetentionAge: maximumAge
      )) { error in
        XCTAssertEqual(error as? HostMediaLiveLogError, .invalidRetentionPolicy)
      }
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

  private func makeProductLog(
    index: Int,
    in directory: URL,
    modifiedAt: Date
  ) throws -> URL {
    let url = productLogURL(index: index, in: directory)
    try Data("{}\n".utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.modificationDate: modifiedAt],
      ofItemAtPath: url.path
    )
    return url
  }

  private func productLogURL(index: Int, in directory: URL) -> URL {
    let uuid = String(format: "00000000-0000-0000-0000-%012d", index)
    return directory.appendingPathComponent(
      "host-media-live-2026-08-08T000000Z-\(uuid).jsonl"
    )
  }
}

private enum HostMediaLiveLogRemovalFailure: Error {
  case denied
}
