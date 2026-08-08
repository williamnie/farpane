import Foundation
import XCTest

@testable import VideoPipeline

final class HostRuntimeStateEvidenceTests: XCTestCase {
  func testWriterUsesSanitizedVersionedAllowlistAndThrottlesPeriodicRecords() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try HostRuntimeStateEvidenceWriter(outputURL: fixture.output)

    XCTAssertTrue(try writer.record(
      hostRuntimeActive: false,
      hostState: "unavailable",
      registrationStatus: "unavailable",
      hostSnapshotObservedAtUnixMilliseconds: nil,
      mediaRouteActive: false,
      mediaPipelineActive: false,
      force: true,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      monotonicNanoseconds: 1_000_000_000
    ))
    XCTAssertFalse(try writer.record(
      hostRuntimeActive: true,
      hostState: "starting",
      registrationStatus: "pending",
      hostSnapshotObservedAtUnixMilliseconds: 1_700_000_000_500,
      mediaRouteActive: false,
      mediaPipelineActive: false,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
      monotonicNanoseconds: 1_500_000_000
    ))
    XCTAssertTrue(try writer.record(
      hostRuntimeActive: true,
      hostState: "ready",
      registrationStatus: "ready",
      hostSnapshotObservedAtUnixMilliseconds: 1_700_000_001_000,
      mediaRouteActive: false,
      mediaPipelineActive: false,
      capturedAt: Date(timeIntervalSince1970: 1_700_000_001),
      monotonicNanoseconds: 2_000_000_000
    ))

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records.map { $0["sequence"] as? Int }, [1, 2])
    XCTAssertEqual(records.map { $0["schema"] as? String }, [
      "farpane-host-runtime-state", "farpane-host-runtime-state",
    ])
    XCTAssertEqual(records.map { $0["schemaVersion"] as? Int }, [1, 1])
    XCTAssertEqual(records[0]["hostRuntimeActive"] as? Bool, false)
    XCTAssertEqual(records[1]["hostRuntimeActive"] as? Bool, true)
    XCTAssertEqual(records[1]["hostState"] as? String, "ready")
    XCTAssertEqual(records[1]["registrationStatus"] as? String, "ready")
    XCTAssertEqual(records[1]["mediaRouteActive"] as? Bool, false)
    XCTAssertEqual(records[1]["mediaPipelineActive"] as? Bool, false)
    XCTAssertEqual(Set(records[1].keys), [
      "schema", "schemaVersion", "sequence", "capturedAt",
      "monotonicNanoseconds", "hostRuntimeActive", "hostState",
      "registrationStatus", "hostSnapshotObservedAtUnixMilliseconds",
      "mediaRouteActive", "mediaPipelineActive",
    ])

    let contents = try String(contentsOf: fixture.output, encoding: .utf8)
    for forbidden in [
      "localId", "instanceId", "peer", "connectionId", "server",
      "password", "publicKey", "credential", "payload", "outputURL",
    ] {
      XCTAssertFalse(contents.localizedCaseInsensitiveContains(forbidden))
    }
  }

  func testForcedLifecycleTransitionsBypassPeriodicThrottle() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try HostRuntimeStateEvidenceWriter(outputURL: fixture.output)

    for (index, routeActive) in [false, true, false].enumerated() {
      XCTAssertTrue(try writer.record(
        hostRuntimeActive: true,
        hostState: "ready",
        registrationStatus: "ready",
        hostSnapshotObservedAtUnixMilliseconds: UInt64(100 + index),
        mediaRouteActive: routeActive,
        mediaPipelineActive: routeActive,
        force: true,
        capturedAt: Date(timeIntervalSince1970: Double(index)),
        monotonicNanoseconds: UInt64(100 + index)
      ))
    }

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.map { $0["sequence"] as? Int }, [1, 2, 3])
    XCTAssertEqual(records.map { $0["mediaRouteActive"] as? Bool }, [
      false, true, false,
    ])
  }

  func testConfigurationDefaultsOffAndFailsClosed() throws {
    XCTAssertNil(try HostRuntimeStateEvidenceWriter.configured(environment: [:]))
    XCTAssertThrowsError(try HostRuntimeStateEvidenceWriter.configured(
      environment: [HostRuntimeStateEvidenceWriter.outputEnvironmentKey: "relative.jsonl"]
    )) { error in
      XCTAssertEqual(
        error as? HostRuntimeStateEvidenceError,
        .outputPathMustBeAbsolute
      )
    }

    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    XCTAssertThrowsError(try HostRuntimeStateEvidenceWriter(
      outputURL: fixture.output.deletingPathExtension().appendingPathExtension("json")
    )) { error in
      XCTAssertEqual(error as? HostRuntimeStateEvidenceError, .outputMustBeJSONLines)
    }
    _ = try HostRuntimeStateEvidenceWriter(outputURL: fixture.output)
    XCTAssertThrowsError(try HostRuntimeStateEvidenceWriter(outputURL: fixture.output)) { error in
      XCTAssertEqual(error as? HostRuntimeStateEvidenceError, .outputAlreadyExists)
    }
  }

  func testInvalidStateValuesAreNotPersisted() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try HostRuntimeStateEvidenceWriter(outputURL: fixture.output)

    XCTAssertThrowsError(try writer.record(
      hostRuntimeActive: true,
      hostState: "ready-with-secret-detail",
      registrationStatus: "ready",
      hostSnapshotObservedAtUnixMilliseconds: nil,
      mediaRouteActive: false,
      mediaPipelineActive: false,
      force: true
    )) { error in
      XCTAssertEqual(error as? HostRuntimeStateEvidenceError, .invalidHostState)
    }
    XCTAssertThrowsError(try writer.record(
      hostRuntimeActive: true,
      hostState: "ready",
      registrationStatus: "ready:server-detail",
      hostSnapshotObservedAtUnixMilliseconds: nil,
      mediaRouteActive: false,
      mediaPipelineActive: false,
      force: true
    )) { error in
      XCTAssertEqual(
        error as? HostRuntimeStateEvidenceError,
        .invalidRegistrationStatus
      )
    }
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
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

  private func makeFixture() throws -> (directory: URL, output: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("farpane-host-runtime-state-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, directory.appendingPathComponent("runtime-state.jsonl"))
  }
}
