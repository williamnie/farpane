import Foundation
import XCTest

@testable import VideoPipeline

final class HostRecoveryTransitionEvidenceTests: XCTestCase {
  private let scopeDigest = String(repeating: "a", count: 64)
  private let buildDigest = String(repeating: "b", count: 64)

  func testWriterEmitsThreeStrictSanitizedCorrelationShapes() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output)
    let acceptedAt = Date(timeIntervalSince1970: 1_700_000_000)

    XCTAssertEqual(try writer.recordCompleted(
      correlation: .sleepWake(recoveryEpoch: 7),
      acceptedAt: acceptedAt,
      completedAt: acceptedAt.addingTimeInterval(1),
      acceptedMonotonicNanoseconds: 100,
      completedMonotonicNanoseconds: 200
    ), 1)
    XCTAssertEqual(try writer.recordCompleted(
      correlation: .networkPath(pathGeneration: 3, recoveryEpoch: 8),
      acceptedAt: acceptedAt.addingTimeInterval(2),
      completedAt: acceptedAt.addingTimeInterval(3),
      acceptedMonotonicNanoseconds: 300,
      completedMonotonicNanoseconds: 400
    ), 2)
    XCTAssertEqual(try writer.recordCompleted(
      correlation: .displayReconfigure(
        previousDisplayRevision: 1,
        replacementDisplayRevision: 1,
        previousConnectionEpoch: 10,
        replacementConnectionEpoch: 11,
        previousCodecEpoch: 20,
        replacementCodecEpoch: 21
      ),
      acceptedAt: acceptedAt.addingTimeInterval(4),
      completedAt: acceptedAt.addingTimeInterval(5),
      acceptedMonotonicNanoseconds: 500,
      completedMonotonicNanoseconds: 600
    ), 3)

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 3)
    XCTAssertEqual(records.map { $0["sequence"] as? Int }, [1, 2, 3])
    XCTAssertEqual(records.map { $0["kind"] as? String }, [
      "sleepWake", "networkPath", "displayReconfigure",
    ])
    XCTAssertEqual(Set(records[0].keys), [
      "schema", "schemaVersion", "sequence", "kind", "acceptedAt",
      "completedAt", "acceptedMonotonicNanoseconds",
      "completedMonotonicNanoseconds", "status",
      "hostInstanceScopeSHA256", "buildIdentitySHA256", "correlation",
    ])
    XCTAssertTrue(records.allSatisfy {
      $0["schema"] as? String == "farpane-host-recovery-transition"
        && $0["schemaVersion"] as? Int == 1
        && $0["status"] as? String == "completed"
        && $0["hostInstanceScopeSHA256"] as? String == scopeDigest
        && $0["buildIdentitySHA256"] as? String == buildDigest
    })

    let sleep = try XCTUnwrap(records[0]["correlation"] as? [String: Any])
    XCTAssertEqual(Set(sleep.keys), [
      "recoveryEpoch", "runningReadyConverged",
    ])
    XCTAssertEqual(sleep["recoveryEpoch"] as? Int, 7)
    XCTAssertEqual(sleep["runningReadyConverged"] as? Bool, true)

    let network = try XCTUnwrap(records[1]["correlation"] as? [String: Any])
    XCTAssertEqual(Set(network.keys), [
      "pathGeneration", "recoveryEpoch", "runningReadyConverged",
    ])
    XCTAssertEqual(network["pathGeneration"] as? Int, 3)
    XCTAssertEqual(network["recoveryEpoch"] as? Int, 8)

    let display = try XCTUnwrap(records[2]["correlation"] as? [String: Any])
    XCTAssertEqual(Set(display.keys), [
      "previousDisplayRevision", "replacementDisplayRevision",
      "previousConnectionEpoch", "replacementConnectionEpoch",
      "previousCodecEpoch", "replacementCodecEpoch", "freshRouteConverged",
    ])
    XCTAssertEqual(display["previousDisplayRevision"] as? Int, 1)
    XCTAssertEqual(display["replacementDisplayRevision"] as? Int, 1)
    XCTAssertEqual(display["freshRouteConverged"] as? Bool, true)

    let contents = try String(contentsOf: fixture.output, encoding: .utf8)
    for forbidden in [
      "localId", "hostInstanceId", "peer", "connectionId", "server",
      "password", "publicKey", "credential", "payload", "displayId",
    ] {
      XCTAssertFalse(contents.localizedCaseInsensitiveContains(forbidden))
    }
  }

  func testConfigurationDefaultsOffAndRejectsPartialOrUnsafeValues() throws {
    XCTAssertNil(try HostRecoveryTransitionEvidenceWriter.configured(
      environment: [:]
    ))
    for environment in [
      [HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey: "/tmp/a.jsonl"],
      [HostRecoveryTransitionEvidenceWriter.hostInstanceScopeDigestEnvironmentKey:
        scopeDigest],
      [HostRecoveryTransitionEvidenceWriter.buildIdentityDigestEnvironmentKey:
        buildDigest],
    ] {
      XCTAssertThrowsError(try HostRecoveryTransitionEvidenceWriter.configured(
        environment: environment
      )) { error in
        XCTAssertEqual(
          error as? HostRecoveryTransitionEvidenceError,
          .incompleteConfiguration
        )
      }
    }

    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    XCTAssertThrowsError(try HostRecoveryTransitionEvidenceWriter(
      outputURL: try XCTUnwrap(URL(string: "relative.jsonl")),
      hostInstanceScopeSHA256: scopeDigest,
      buildIdentitySHA256: buildDigest
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .outputPathMustBeAbsolute
      )
    }
    XCTAssertThrowsError(try HostRecoveryTransitionEvidenceWriter(
      outputURL: try XCTUnwrap(URL(string: "https://example.test/recovery.jsonl")),
      hostInstanceScopeSHA256: scopeDigest,
      buildIdentitySHA256: buildDigest
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .outputPathMustBeAbsolute
      )
    }
    XCTAssertThrowsError(try HostRecoveryTransitionEvidenceWriter(
      outputURL: fixture.output.deletingPathExtension().appendingPathExtension("json"),
      hostInstanceScopeSHA256: scopeDigest,
      buildIdentitySHA256: buildDigest
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .outputMustBeJSONLines
      )
    }
    XCTAssertThrowsError(try HostRecoveryTransitionEvidenceWriter(
      outputURL: fixture.output,
      hostInstanceScopeSHA256: String(repeating: "A", count: 64),
      buildIdentitySHA256: buildDigest
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .invalidHostInstanceScopeDigest
      )
    }
    XCTAssertThrowsError(try HostRecoveryTransitionEvidenceWriter(
      outputURL: fixture.output,
      hostInstanceScopeSHA256: scopeDigest,
      buildIdentitySHA256: "not-a-digest"
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .invalidBuildIdentityDigest
      )
    }
    _ = try makeWriter(fixture.output)
    XCTAssertThrowsError(try makeWriter(fixture.output)) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .outputAlreadyExists
      )
    }
  }

  func testInvalidTimingAndCorrelationDoNotAppendPartialEvidence() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    XCTAssertThrowsError(try writer.recordCompleted(
      correlation: .sleepWake(recoveryEpoch: 1),
      acceptedAt: now,
      completedAt: now.addingTimeInterval(-1),
      acceptedMonotonicNanoseconds: 100,
      completedMonotonicNanoseconds: 200
    )) { error in
      XCTAssertEqual(error as? HostRecoveryTransitionEvidenceError, .invalidTiming)
    }
    XCTAssertThrowsError(try writer.recordCompleted(
      correlation: .networkPath(pathGeneration: 0, recoveryEpoch: 1),
      acceptedAt: now,
      completedAt: now,
      acceptedMonotonicNanoseconds: 100,
      completedMonotonicNanoseconds: 200
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .invalidCorrelation
      )
    }
    XCTAssertThrowsError(try writer.recordCompleted(
      correlation: .displayReconfigure(
        previousDisplayRevision: 1,
        replacementDisplayRevision: 1,
        previousConnectionEpoch: 10,
        replacementConnectionEpoch: 10,
        previousCodecEpoch: 20,
        replacementCodecEpoch: 21
      ),
      acceptedAt: now,
      completedAt: now,
      acceptedMonotonicNanoseconds: 100,
      completedMonotonicNanoseconds: 200
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .invalidCorrelation
      )
    }
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
  }

  func testConcurrentRecordsHaveUniqueBoundedSequence() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output)
    let group = DispatchGroup()
    let failures = FailureCollector()

    for index in 1...64 {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        do {
          try writer.recordCompleted(
            correlation: .sleepWake(recoveryEpoch: UInt64(index)),
            acceptedAt: Date(timeIntervalSince1970: Double(index)),
            completedAt: Date(timeIntervalSince1970: Double(index + 1)),
            acceptedMonotonicNanoseconds: UInt64(index * 2 - 1),
            completedMonotonicNanoseconds: UInt64(index * 2)
          )
        } catch {
          failures.append(error)
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(failures.snapshot().count, 0)
    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 64)
    XCTAssertEqual(
      Set(records.compactMap { $0["sequence"] as? Int }),
      Set(1...64)
    )
  }

  func testWriterFailsClosedAtRecordCapacity() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output)
    for index in 1...HostRecoveryTransitionEvidenceWriter.maximumRecordCount {
      XCTAssertEqual(try writer.recordCompleted(
        correlation: .sleepWake(recoveryEpoch: index),
        acceptedAt: Date(timeIntervalSince1970: Double(index)),
        completedAt: Date(timeIntervalSince1970: Double(index + 1)),
        acceptedMonotonicNanoseconds: index * 2 - 1,
        completedMonotonicNanoseconds: index * 2
      ), index)
    }
    XCTAssertThrowsError(try writer.recordCompleted(
      correlation: .sleepWake(recoveryEpoch: 129),
      acceptedAt: Date(timeIntervalSince1970: 129),
      completedAt: Date(timeIntervalSince1970: 130),
      acceptedMonotonicNanoseconds: 257,
      completedMonotonicNanoseconds: 258
    )) { error in
      XCTAssertEqual(
        error as? HostRecoveryTransitionEvidenceError,
        .recordCapacityExceeded
      )
    }
    XCTAssertEqual(try readRecords(fixture.output).count, 128)
  }

  private func makeWriter(
    _ output: URL
  ) throws -> HostRecoveryTransitionEvidenceWriter {
    try HostRecoveryTransitionEvidenceWriter(
      outputURL: output,
      hostInstanceScopeSHA256: scopeDigest,
      buildIdentitySHA256: buildDigest
    )
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
      .appendingPathComponent(
        "farpane-host-recovery-transition-tests",
        isDirectory: true
      )
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, directory.appendingPathComponent("recovery.jsonl"))
  }
}

private final class FailureCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var failures: [Error] = []

  func append(_ error: Error) {
    lock.lock()
    failures.append(error)
    lock.unlock()
  }

  func snapshot() -> [Error] {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }
}
