import Foundation
import XCTest

@testable import VideoPipeline

final class HostRecoveryTransitionEvidenceProcessOwnerTests: XCTestCase {
  func testMissingOutputKeepsOwnerExplicitlyDisabled() {
    let owner = HostRecoveryTransitionEvidenceProcessOwner()

    XCTAssertTrue(owner.configure(
      hostInstanceID: "host-instance-1",
      buildIdentity: "build-1",
      environment: [:]
    ))
    XCTAssertEqual(owner.snapshot(), .init(
      status: .disabled,
      completedRecords: 0,
      configurationFailures: 0,
      recordFailures: 0
    ))
    XCTAssertFalse(owner.recordCompleted(
      correlation: .sleepWake(recoveryEpoch: 1),
      acceptedAt: Date(timeIntervalSince1970: 1),
      completedAt: Date(timeIntervalSince1970: 2),
      acceptedMonotonicNanoseconds: 1,
      completedMonotonicNanoseconds: 2
    ))
  }

  func testConfiguredOwnerDerivesDomainSeparatedDigestsAndWritesNoRawIdentity() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = HostRecoveryTransitionEvidenceProcessOwner()
    let hostInstanceID = "host-instance-private"
    let buildIdentity = "build-identity-private"

    XCTAssertTrue(owner.configure(
      hostInstanceID: hostInstanceID,
      buildIdentity: buildIdentity,
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))
    XCTAssertTrue(owner.recordCompleted(
      correlation: .networkPath(pathGeneration: 2, recoveryEpoch: 3),
      acceptedAt: Date(timeIntervalSince1970: 1),
      completedAt: Date(timeIntervalSince1970: 2),
      acceptedMonotonicNanoseconds: 10,
      completedMonotonicNanoseconds: 20
    ))

    let document = try readOnlyRecord(fixture.output)
    let scopeDigest = try XCTUnwrap(
      HostRecoveryTransitionEvidenceProcessOwner.scopeDigest(
        for: hostInstanceID
      )
    )
    let buildDigest = try XCTUnwrap(
      HostRecoveryTransitionEvidenceProcessOwner.buildDigest(
        for: buildIdentity
      )
    )
    XCTAssertEqual(document["hostInstanceScopeSHA256"] as? String, scopeDigest)
    XCTAssertEqual(document["buildIdentitySHA256"] as? String, buildDigest)
    XCTAssertEqual(scopeDigest.count, 64)
    XCTAssertEqual(buildDigest.count, 64)
    XCTAssertNotEqual(scopeDigest, buildDigest)
    let contents = try String(contentsOf: fixture.output, encoding: .utf8)
    XCTAssertFalse(contents.contains(hostInstanceID))
    XCTAssertFalse(contents.contains(buildIdentity))
    XCTAssertEqual(owner.snapshot(), .init(
      status: .active,
      completedRecords: 1,
      configurationFailures: 0,
      recordFailures: 0
    ))
  }

  func testMalformedIdentityOrOutputDisablesOnlyEvidence() {
    for (host, build, environment) in [
      ("", "build", [:]),
      ("host", "bad\nbuild", [:]),
      (
        "host",
        "build",
        [HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          "relative.jsonl"]
      ),
    ] {
      let owner = HostRecoveryTransitionEvidenceProcessOwner()
      XCTAssertFalse(owner.configure(
        hostInstanceID: host,
        buildIdentity: build,
        environment: environment
      ))
      XCTAssertEqual(owner.snapshot(), .init(
        status: .unavailable,
        completedRecords: 0,
        configurationFailures: 1,
        recordFailures: 0
      ))
      XCTAssertFalse(owner.recordCompleted(
        correlation: .sleepWake(recoveryEpoch: 1),
        acceptedAt: Date(timeIntervalSince1970: 1),
        completedAt: Date(timeIntervalSince1970: 2),
        acceptedMonotonicNanoseconds: 1,
        completedMonotonicNanoseconds: 2
      ))
    }
  }

  func testRecordFailurePermanentlyDisablesEvidenceWithoutThrowing() {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = HostRecoveryTransitionEvidenceProcessOwner()
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))

    XCTAssertFalse(owner.recordCompleted(
      correlation: .sleepWake(recoveryEpoch: 0),
      acceptedAt: Date(timeIntervalSince1970: 1),
      completedAt: Date(timeIntervalSince1970: 2),
      acceptedMonotonicNanoseconds: 1,
      completedMonotonicNanoseconds: 2
    ))
    XCTAssertEqual(owner.snapshot(), .init(
      status: .unavailable,
      completedRecords: 0,
      configurationFailures: 0,
      recordFailures: 1
    ))
    XCTAssertFalse(owner.recordCompleted(
      correlation: .sleepWake(recoveryEpoch: 1),
      acceptedAt: Date(timeIntervalSince1970: 1),
      completedAt: Date(timeIntervalSince1970: 2),
      acceptedMonotonicNanoseconds: 1,
      completedMonotonicNanoseconds: 2
    ))
    XCTAssertEqual((try? Data(contentsOf: fixture.output).count), 0)
  }

  func testSleepWakeEvidenceRequiresExactAcceptedEpochAndPreservesTiming() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = RecoveryEvidenceTestClock(
      wallTimes: [
        Date(timeIntervalSince1970: 10),
        Date(timeIntervalSince1970: 20),
      ],
      monotonicTimes: [100, 200]
    )
    let owner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: { clock.nextWallTime() },
      monotonicNanoseconds: { clock.nextMonotonicTime() }
    )
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))

    XCTAssertTrue(owner.acceptSleepWake(recoveryEpoch: 7))
    XCTAssertFalse(owner.acceptSleepWake(recoveryEpoch: 7))
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
    XCTAssertFalse(owner.recordSleepWakeCompleted(recoveryEpoch: 8))
    XCTAssertTrue(owner.recordSleepWakeCompleted(recoveryEpoch: 7))
    XCTAssertFalse(owner.recordSleepWakeCompleted(recoveryEpoch: 7))

    let document = try readOnlyRecord(fixture.output)
    XCTAssertEqual(document["kind"] as? String, "sleepWake")
    let correlation = try XCTUnwrap(
      document["correlation"] as? [String: Any]
    )
    XCTAssertEqual(correlation["recoveryEpoch"] as? Int, 7)
    XCTAssertEqual(correlation["runningReadyConverged"] as? Bool, true)
    XCTAssertEqual(
      document["acceptedMonotonicNanoseconds"] as? Int,
      100
    )
    XCTAssertEqual(
      document["completedMonotonicNanoseconds"] as? Int,
      200
    )
    XCTAssertEqual(owner.snapshot(), .init(
      status: .active,
      completedRecords: 1,
      configurationFailures: 0,
      recordFailures: 0
    ))
  }

  func testCancellationDrainsAcceptedSleepWakeClockSampling() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let samplingEntered = DispatchSemaphore(value: 0)
    let releaseSampling = DispatchSemaphore(value: 0)
    let cancellationFinished = DispatchSemaphore(value: 0)
    let acceptanceFinished = expectation(description: "acceptance finished")
    let owner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: {
        samplingEntered.signal()
        releaseSampling.wait()
        return Date(timeIntervalSince1970: 10)
      },
      monotonicNanoseconds: { 100 }
    )
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))

    DispatchQueue.global().async {
      XCTAssertFalse(owner.acceptSleepWake(recoveryEpoch: 1))
      acceptanceFinished.fulfill()
    }
    XCTAssertEqual(samplingEntered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global().async {
      owner.cancelAndWait()
      cancellationFinished.signal()
    }
    XCTAssertEqual(
      cancellationFinished.wait(timeout: .now() + 0.05),
      .timedOut
    )

    releaseSampling.signal()
    wait(for: [acceptanceFinished], timeout: 1)
    XCTAssertEqual(
      cancellationFinished.wait(timeout: .now() + 1),
      .success
    )
    XCTAssertEqual(owner.snapshot().status, .cancelled)
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
  }

  func testNetworkEvidenceRequiresExactGenerationEpochAndPreservesTiming() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = RecoveryEvidenceTestClock(
      wallTimes: [
        Date(timeIntervalSince1970: 30),
        Date(timeIntervalSince1970: 40),
      ],
      monotonicTimes: [300, 400]
    )
    let owner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: { clock.nextWallTime() },
      monotonicNanoseconds: { clock.nextMonotonicTime() }
    )
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))

    XCTAssertTrue(owner.acceptNetworkPath(
      pathGeneration: 3,
      recoveryEpoch: 0
    ))
    XCTAssertFalse(owner.acceptNetworkPath(
      pathGeneration: 3,
      recoveryEpoch: 0
    ))
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
    XCTAssertFalse(owner.recordNetworkPathCompleted(
      pathGeneration: 4,
      recoveryEpoch: 0
    ))
    XCTAssertFalse(owner.recordNetworkPathCompleted(
      pathGeneration: 3,
      recoveryEpoch: 1
    ))
    XCTAssertTrue(owner.recordNetworkPathCompleted(
      pathGeneration: 3,
      recoveryEpoch: 0
    ))
    XCTAssertFalse(owner.recordNetworkPathCompleted(
      pathGeneration: 3,
      recoveryEpoch: 0
    ))

    let document = try readOnlyRecord(fixture.output)
    XCTAssertEqual(document["kind"] as? String, "networkPath")
    let correlation = try XCTUnwrap(
      document["correlation"] as? [String: Any]
    )
    XCTAssertEqual(correlation["pathGeneration"] as? Int, 3)
    XCTAssertEqual(correlation["recoveryEpoch"] as? Int, 0)
    XCTAssertEqual(correlation["runningReadyConverged"] as? Bool, true)
    XCTAssertEqual(
      document["acceptedMonotonicNanoseconds"] as? Int,
      300
    )
    XCTAssertEqual(
      document["completedMonotonicNanoseconds"] as? Int,
      400
    )
    XCTAssertEqual(owner.snapshot(), .init(
      status: .active,
      completedRecords: 1,
      configurationFailures: 0,
      recordFailures: 0
    ))
  }

  func testCancellationDrainsAcceptedNetworkPathClockSampling() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let samplingEntered = DispatchSemaphore(value: 0)
    let releaseSampling = DispatchSemaphore(value: 0)
    let cancellationFinished = DispatchSemaphore(value: 0)
    let acceptanceFinished = expectation(description: "acceptance finished")
    let owner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: {
        samplingEntered.signal()
        releaseSampling.wait()
        return Date(timeIntervalSince1970: 30)
      },
      monotonicNanoseconds: { 300 }
    )
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))

    DispatchQueue.global().async {
      XCTAssertFalse(owner.acceptNetworkPath(
        pathGeneration: 1,
        recoveryEpoch: 2
      ))
      acceptanceFinished.fulfill()
    }
    XCTAssertEqual(samplingEntered.wait(timeout: .now() + 1), .success)
    DispatchQueue.global().async {
      owner.cancelAndWait()
      cancellationFinished.signal()
    }
    XCTAssertEqual(
      cancellationFinished.wait(timeout: .now() + 0.05),
      .timedOut
    )

    releaseSampling.signal()
    wait(for: [acceptanceFinished], timeout: 1)
    XCTAssertEqual(
      cancellationFinished.wait(timeout: .now() + 1),
      .success
    )
    XCTAssertEqual(owner.snapshot().status, .cancelled)
    XCTAssertEqual(try Data(contentsOf: fixture.output).count, 0)
  }

  func testDisplayEvidenceRequiresExactMarkerAndFreshReplacement() throws {
    let fixture = makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let clock = RecoveryEvidenceTestClock(
      wallTimes: [
        Date(timeIntervalSince1970: 50),
        Date(timeIntervalSince1970: 60),
      ],
      monotonicTimes: [500, 600]
    )
    let owner = HostRecoveryTransitionEvidenceProcessOwner(
      wallClock: { clock.nextWallTime() },
      monotonicNanoseconds: { clock.nextMonotonicTime() }
    )
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [
        HostRecoveryTransitionEvidenceWriter.outputEnvironmentKey:
          fixture.output.path,
      ]
    ))

    XCTAssertTrue(owner.acceptDisplayReconfigure(
      generation: 5,
      displayID: 0,
      previousDisplayRevision: 2,
      previousConnectionEpoch: 11,
      previousCodecEpoch: 21
    ))
    XCTAssertFalse(owner.acceptDisplayReconfigure(
      generation: 5,
      displayID: 0,
      previousDisplayRevision: 2,
      previousConnectionEpoch: 11,
      previousCodecEpoch: 21
    ))
    XCTAssertFalse(owner.recordDisplayReconfigureCompleted(
      generation: 6,
      displayID: 0,
      previousDisplayRevision: 2,
      replacementDisplayRevision: 3,
      previousConnectionEpoch: 11,
      replacementConnectionEpoch: 12,
      previousCodecEpoch: 21,
      replacementCodecEpoch: 22
    ))
    XCTAssertFalse(owner.recordDisplayReconfigureCompleted(
      generation: 5,
      displayID: 0,
      previousDisplayRevision: 2,
      replacementDisplayRevision: 2,
      previousConnectionEpoch: 11,
      replacementConnectionEpoch: 12,
      previousCodecEpoch: 21,
      replacementCodecEpoch: 22
    ))
    XCTAssertTrue(owner.recordDisplayReconfigureCompleted(
      generation: 5,
      displayID: 0,
      previousDisplayRevision: 2,
      replacementDisplayRevision: 3,
      previousConnectionEpoch: 11,
      replacementConnectionEpoch: 12,
      previousCodecEpoch: 21,
      replacementCodecEpoch: 22
    ))

    let document = try readOnlyRecord(fixture.output)
    XCTAssertEqual(document["kind"] as? String, "displayReconfigure")
    let correlation = try XCTUnwrap(
      document["correlation"] as? [String: Any]
    )
    XCTAssertEqual(correlation["previousDisplayRevision"] as? Int, 2)
    XCTAssertEqual(correlation["replacementDisplayRevision"] as? Int, 3)
    XCTAssertEqual(correlation["previousConnectionEpoch"] as? Int, 11)
    XCTAssertEqual(correlation["replacementConnectionEpoch"] as? Int, 12)
    XCTAssertEqual(correlation["previousCodecEpoch"] as? Int, 21)
    XCTAssertEqual(correlation["replacementCodecEpoch"] as? Int, 22)
    XCTAssertEqual(correlation["freshRouteConverged"] as? Bool, true)
    XCTAssertEqual(owner.snapshot().completedRecords, 1)
  }

  func testConfigurationAndCancellationAreTerminalOneShotOperations() {
    let owner = HostRecoveryTransitionEvidenceProcessOwner()
    XCTAssertTrue(owner.configure(
      hostInstanceID: "host",
      buildIdentity: "build",
      environment: [:]
    ))
    XCTAssertFalse(owner.configure(
      hostInstanceID: "host-2",
      buildIdentity: "build-2",
      environment: [:]
    ))
    owner.cancelAndWait()
    owner.cancelAndWait()
    XCTAssertEqual(owner.snapshot(), .init(
      status: .cancelled,
      completedRecords: 0,
      configurationFailures: 0,
      recordFailures: 0
    ))
    XCTAssertFalse(owner.configure(
      hostInstanceID: "host-3",
      buildIdentity: "build-3",
      environment: [:]
    ))
  }

  private func readOnlyRecord(_ url: URL) throws -> [String: Any] {
    let lines = try String(contentsOf: url, encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(lines.count, 1)
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try XCTUnwrap(lines.first).utf8))
        as? [String: Any]
    )
  }

  private func makeFixture() -> (directory: URL, output: URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "farpane-host-recovery-evidence-process-owner-tests",
        isDirectory: true
      )
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (directory, directory.appendingPathComponent("recovery.jsonl"))
  }
}

private final class RecoveryEvidenceTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var wallTimes: [Date]
  private var monotonicTimes: [UInt64]

  init(wallTimes: [Date], monotonicTimes: [UInt64]) {
    self.wallTimes = wallTimes
    self.monotonicTimes = monotonicTimes
  }

  func nextWallTime() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return wallTimes.removeFirst()
  }

  func nextMonotonicTime() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return monotonicTimes.removeFirst()
  }
}
