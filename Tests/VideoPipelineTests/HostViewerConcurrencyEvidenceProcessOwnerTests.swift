import Darwin
import Foundation
import XCTest

@testable import VideoPipeline

final class HostViewerConcurrencyEvidenceProcessOwnerTests: XCTestCase {
  private let scenarioRaw = "scenario-private-value"
  private let processStartRaw = "process-start-private-value"
  private let buildRaw = "build-private-value"

  func testMissingOutputDisablesBeforeResolvingAnyIdentity() {
    let calls = LockedCallCounts()
    let owner = HostViewerConcurrencyEvidenceProcessOwner(
      processID: {
        calls.incrementProcessID()
        return 4_242
      },
      processStartIdentity: { _ in
        calls.incrementProcessStart()
        return "must-not-be-read"
      },
      buildIdentity: {
        calls.incrementBuild()
        return "must-not-be-read"
      }
    )

    XCTAssertTrue(owner.configureApplication(environment: [:]))
    XCTAssertEqual(calls.snapshot(), .init(
      processID: 0,
      processStart: 0,
      build: 0
    ))
    XCTAssertEqual(owner.snapshot(), .init(
      status: .disabled,
      processStartedRecords: 0,
      processTerminatingRecords: 0,
      configurationFailures: 0,
      recordFailures: 0
    ))
    XCTAssertFalse(owner.configureApplication(environment: [:]))
    XCTAssertTrue(owner.terminateAndWait())
    XCTAssertFalse(owner.terminateAndWait())
    XCTAssertEqual(owner.snapshot().status, .terminated)
  }

  func testConfiguredOwnerWritesOnlySanitizedProcessLifetimeEdges() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = ProcessEvidenceTestClock(
      dates: [
        Date(timeIntervalSince1970: 1_700_000_000),
        Date(timeIntervalSince1970: 1_700_000_001),
      ],
      monotonic: [100, 200]
    )
    let owner = makeOwner(clock: clock)

    XCTAssertTrue(owner.configureApplication(environment: environment(
      output: fixture.output
    )))
    XCTAssertEqual(owner.snapshot(), .init(
      status: .active,
      processStartedRecords: 1,
      processTerminatingRecords: 0,
      configurationFailures: 0,
      recordFailures: 0
    ))
    XCTAssertFalse(owner.configureApplication(environment: environment(
      output: fixture.output
    )))
    XCTAssertTrue(owner.terminateAndWait())
    XCTAssertFalse(owner.terminateAndWait())
    XCTAssertEqual(owner.snapshot(), .init(
      status: .terminated,
      processStartedRecords: 1,
      processTerminatingRecords: 1,
      configurationFailures: 0,
      recordFailures: 0
    ))

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records.compactMap { $0["sequence"] as? Int }, [1, 2])
    XCTAssertEqual(records.compactMap {
      ($0["event"] as? [String: Any])?["kind"] as? String
    }, ["processStarted", "processTerminating"])
    XCTAssertTrue(records.allSatisfy {
      $0["observerProcessRole"] as? String == "application"
        && $0["observerProcessID"] as? Int == 4_242
        && $0["observerProcessStartIdentitySHA256"] as? String
          == HostViewerConcurrencyEvidenceDigest.processStartIdentity(
            processStartRaw
          )
        && $0["observerBuildIdentitySHA256"] as? String
          == HostViewerConcurrencyEvidenceDigest.buildIdentity(buildRaw)
        && $0["scenarioCorrelationSHA256"] as? String
          == HostViewerConcurrencyEvidenceDigest.scenarioCorrelation(
            scenarioRaw
          )
    })
    let contents = try String(contentsOf: fixture.output, encoding: .utf8)
    XCTAssertFalse(contents.contains(processStartRaw))
    XCTAssertFalse(contents.contains(buildRaw))
    XCTAssertFalse(contents.contains(scenarioRaw))
  }

  func testMalformedExplicitConfigurationOnlyMakesEvidenceUnavailable() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let missingScenario = makeOwner()
    XCTAssertFalse(missingScenario.configureApplication(environment: [
      HostViewerConcurrencyEvidenceWriter.outputEnvironmentKey:
        fixture.output.path,
    ]))
    XCTAssertEqual(missingScenario.snapshot(), .init(
      status: .unavailable,
      processStartedRecords: 0,
      processTerminatingRecords: 0,
      configurationFailures: 1,
      recordFailures: 0
    ))
    XCTAssertFalse(missingScenario.terminateAndWait())

    let invalidProcess = HostViewerConcurrencyEvidenceProcessOwner(
      processID: { 1 },
      processStartIdentity: { _ in self.processStartRaw },
      buildIdentity: { self.buildRaw }
    )
    XCTAssertFalse(invalidProcess.configureApplication(environment: environment(
      output: fixture.output
    )))
    XCTAssertEqual(invalidProcess.snapshot().status, .unavailable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
  }

  func testTerminationWriteFailureIsTerminalAndNeverThrows() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = ProcessEvidenceTestClock(
      dates: [
        Date(timeIntervalSince1970: 1_700_000_000),
        Date(timeIntervalSince1970: 1_700_000_000),
      ],
      monotonic: [100, 100]
    )
    let owner = makeOwner(clock: clock)

    XCTAssertTrue(owner.configureApplication(environment: environment(
      output: fixture.output
    )))
    XCTAssertFalse(owner.terminateAndWait())
    XCTAssertEqual(owner.snapshot(), .init(
      status: .terminated,
      processStartedRecords: 1,
      processTerminatingRecords: 0,
      configurationFailures: 0,
      recordFailures: 1
    ))
    XCTAssertEqual(try readRecords(fixture.output).count, 1)
  }

  func testConcurrentTerminationRecordsExactlyOneTerminalEdge() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = makeOwner()
    XCTAssertTrue(owner.configureApplication(environment: environment(
      output: fixture.output
    )))
    let results = LockedBooleanResults()
    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      results.append(owner.terminateAndWait())
    }

    XCTAssertEqual(results.snapshot().filter { $0 }.count, 1)
    XCTAssertEqual(owner.snapshot().processTerminatingRecords, 1)
    XCTAssertEqual(try readRecords(fixture.output).count, 2)
  }

  func testCurrentProcessStartIdentityUsesExactKernelProcessRecord() throws {
    let processID = getpid()
    let identity = try XCTUnwrap(
      HostViewerConcurrencyEvidenceProcessOwner
        .currentProcessStartIdentity(processID: processID)
    )

    XCTAssertTrue(identity.hasPrefix("pid=\(processID);sec="))
    XCTAssertTrue(identity.contains(";usec="))
    XCTAssertNil(
      HostViewerConcurrencyEvidenceProcessOwner
        .currentProcessStartIdentity(processID: 1)
    )
  }

  private func makeOwner(
    clock: ProcessEvidenceTestClock? = nil
  ) -> HostViewerConcurrencyEvidenceProcessOwner {
    HostViewerConcurrencyEvidenceProcessOwner(
      processID: { 4_242 },
      processStartIdentity: { _ in self.processStartRaw },
      buildIdentity: { self.buildRaw },
      wallClock: { clock?.nextDate() ?? Date() },
      monotonicNanoseconds: {
        clock?.nextMonotonic() ?? DispatchTime.now().uptimeNanoseconds
      }
    )
  }

  private func environment(output: URL) -> [String: String] {
    [
      HostViewerConcurrencyEvidenceWriter.outputEnvironmentKey: output.path,
      HostViewerConcurrencyEvidenceProcessOwner.scenarioEnvironmentKey:
        scenarioRaw,
    ]
  }

  private func readRecords(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
      .map { line in
        try XCTUnwrap(
          JSONSerialization.jsonObject(with: Data(line.utf8))
            as? [String: Any]
        )
      }
  }

  private func makeFixture() throws -> (directory: URL, output: URL) {
    let temporaryPath = FileManager.default.temporaryDirectory.path
    let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
      ? "/private\(temporaryPath)"
      : temporaryPath
    let root = URL(
      fileURLWithPath: canonicalTemporaryPath,
      isDirectory: true
    )
      .appendingPathComponent(
        "farpane-host-viewer-process-owner-tests",
        isDirectory: true
      )
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: root.path
    )
    return (root, root.appendingPathComponent("app-lifecycle.jsonl"))
  }
}

private final class ProcessEvidenceTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var dates: [Date]
  private var monotonic: [UInt64]

  init(dates: [Date], monotonic: [UInt64]) {
    self.dates = dates
    self.monotonic = monotonic
  }

  func nextDate() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return dates.removeFirst()
  }

  func nextMonotonic() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return monotonic.removeFirst()
  }
}

private final class LockedBooleanResults: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Bool] = []

  func append(_ value: Bool) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }

  func snapshot() -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private final class LockedCallCounts: @unchecked Sendable {
  struct Snapshot: Equatable {
    let processID: Int
    let processStart: Int
    let build: Int
  }

  private let lock = NSLock()
  private var processID = 0
  private var processStart = 0
  private var build = 0

  func incrementProcessID() { increment(\Self.processID) }
  func incrementProcessStart() { increment(\Self.processStart) }
  func incrementBuild() { increment(\Self.build) }

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      processID: processID,
      processStart: processStart,
      build: build
    )
  }

  private func increment(_ keyPath: ReferenceWritableKeyPath<LockedCallCounts, Int>) {
    lock.lock()
    self[keyPath: keyPath] += 1
    lock.unlock()
  }
}
