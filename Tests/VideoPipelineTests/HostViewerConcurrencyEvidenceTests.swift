import Darwin
import Foundation
import XCTest

@testable import VideoPipeline

final class HostViewerConcurrencyEvidenceTests: XCTestCase {
  private let appStartRaw = "app-start-marker"
  private let agentStartRaw = "agent-start-marker"
  private let buildRaw = "build-202608100001"
  private let hostRaw = "host-instance-value"
  private let scenarioRaw = "scenario-run-value"
  private let agentBootID = UUID(
    uuidString: "11111111-2222-3333-4444-555555555555"
  )!

  func testWriterEmitsStrictSanitizedProcessHostAndViewerRecords() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output, role: .application)
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    XCTAssertEqual(try writer.record(
      .processStarted,
      capturedAt: base,
      monotonicNanoseconds: 100
    ), 1)
    XCTAssertEqual(try writer.record(
      .host(hostObservation(
        state: .readyZeroInbound,
        selfObserved: true
      )),
      capturedAt: base.addingTimeInterval(1),
      monotonicNanoseconds: 200
    ), 2)
    XCTAssertEqual(try writer.record(
      .viewer(HostViewerConcurrencyViewerObservation(
        state: .starting,
        sessionEpoch: 7,
        transitionGeneration: 0
      )),
      capturedAt: base.addingTimeInterval(2),
      monotonicNanoseconds: 300
    ), 3)
    XCTAssertEqual(try writer.record(
      .viewer(HostViewerConcurrencyViewerObservation(
        state: .authenticatedStreaming,
        sessionEpoch: 7,
        transitionGeneration: 0
      )),
      capturedAt: base.addingTimeInterval(3),
      monotonicNanoseconds: 400
    ), 4)
    XCTAssertEqual(try writer.record(
      .viewer(HostViewerConcurrencyViewerObservation(
        state: .disconnected,
        sessionEpoch: 7,
        transitionGeneration: 9
      )),
      capturedAt: base.addingTimeInterval(4),
      monotonicNanoseconds: 500
    ), 5)
    XCTAssertEqual(try writer.record(
      .viewer(HostViewerConcurrencyViewerObservation(
        state: .recoveredStreaming,
        sessionEpoch: 7,
        transitionGeneration: 9
      )),
      capturedAt: base.addingTimeInterval(5),
      monotonicNanoseconds: 600
    ), 6)
    XCTAssertEqual(try writer.record(
      .processTerminating,
      capturedAt: base.addingTimeInterval(6),
      monotonicNanoseconds: 700
    ), 7)

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 7)
    XCTAssertEqual(records.map { $0["sequence"] as? Int }, Array(1...7))
    XCTAssertTrue(records.allSatisfy {
      $0["schema"] as? String
        == "farpane-host-viewer-concurrency-lifecycle"
        && $0["schemaVersion"] as? Int == 1
        && $0["observerProcessRole"] as? String == "application"
        && $0["observerProcessID"] as? Int == 101
        && $0["observerProcessStartIdentitySHA256"] as? String
          == processStartDigest(appStartRaw)
        && $0["observerBuildIdentitySHA256"] as? String
          == buildDigest(buildRaw)
        && $0["scenarioCorrelationSHA256"] as? String
          == scenarioDigest(scenarioRaw)
    })
    XCTAssertEqual(Set(records[0].keys), [
      "schema", "schemaVersion", "sequence", "capturedAt",
      "monotonicNanoseconds", "observerProcessRole", "observerProcessID",
      "observerProcessStartIdentitySHA256", "observerBuildIdentitySHA256",
      "scenarioCorrelationSHA256", "event",
    ])

    let process = try XCTUnwrap(records[0]["event"] as? [String: Any])
    XCTAssertEqual(Set(process.keys), ["kind"])
    XCTAssertEqual(process["kind"] as? String, "processStarted")

    let host = try XCTUnwrap(records[1]["event"] as? [String: Any])
    XCTAssertEqual(Set(host.keys), [
      "kind", "state", "hostInstanceScopeSHA256", "agentBootID",
      "configRevision", "hostAgentProcessID",
      "hostAgentProcessStartIdentitySHA256", "hostAgentBuildIdentitySHA256",
      "transitionGeneration",
    ])
    XCTAssertEqual(host["kind"] as? String, "hostState")
    XCTAssertEqual(host["state"] as? String, "readyZeroInbound")
    XCTAssertEqual(host["agentBootID"] as? String, agentBootID.uuidString.lowercased())
    XCTAssertEqual(host["configRevision"] as? Int, 3)
    XCTAssertEqual(host["hostAgentProcessID"] as? Int, 202)

    let viewer = try XCTUnwrap(records[2]["event"] as? [String: Any])
    XCTAssertEqual(Set(viewer.keys), [
      "kind", "state", "sessionEpoch", "transitionGeneration",
    ])
    XCTAssertEqual(viewer["kind"] as? String, "viewerState")
    XCTAssertEqual(viewer["state"] as? String, "starting")
    XCTAssertEqual(viewer["sessionEpoch"] as? Int, 7)

    let contents = try String(contentsOf: fixture.output, encoding: .utf8)
    for rawValue in [appStartRaw, agentStartRaw, buildRaw, hostRaw, scenarioRaw] {
      XCTAssertFalse(contents.contains(rawValue))
    }
    for forbidden in [
      "peerId", "connectionId", "password", "serverPublicKey",
      "credential", "mediaPayload",
    ] {
      XCTAssertFalse(contents.localizedCaseInsensitiveContains(forbidden))
    }

    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.output.path
    )
    XCTAssertEqual(
      (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
      0o600
    )
    XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
  }

  func testDigestDomainsAreDistinctAndRejectRawControlData() throws {
    let raw = "same-raw-value"
    let digests = try [
      XCTUnwrap(HostViewerConcurrencyEvidenceDigest.processStartIdentity(raw)),
      XCTUnwrap(HostViewerConcurrencyEvidenceDigest.buildIdentity(raw)),
      XCTUnwrap(HostViewerConcurrencyEvidenceDigest.hostInstanceScope(raw)),
      XCTUnwrap(HostViewerConcurrencyEvidenceDigest.scenarioCorrelation(raw)),
    ]

    XCTAssertEqual(Set(digests).count, 4)
    XCTAssertTrue(digests.allSatisfy {
      $0.count == 64
        && $0.allSatisfy { "0123456789abcdef".contains($0) }
    })
    XCTAssertNil(HostViewerConcurrencyEvidenceDigest.buildIdentity(""))
    XCTAssertNil(
      HostViewerConcurrencyEvidenceDigest.hostInstanceScope("bad\nidentity")
    )
    XCTAssertNil(
      HostViewerConcurrencyEvidenceDigest.scenarioCorrelation(
        String(repeating: "x", count: 513)
      )
    )
  }

  func testConfigurationDefaultsOffAndRejectsUnsafeOutput() throws {
    let identity = processIdentity(role: .application)
    XCTAssertNil(try HostViewerConcurrencyEvidenceWriter.configured(
      environment: [:],
      identity: identity
    ))
    XCTAssertThrowsError(try HostViewerConcurrencyEvidenceWriter.configured(
      environment: [
        HostViewerConcurrencyEvidenceWriter.outputEnvironmentKey:
          "relative.jsonl",
      ],
      identity: identity
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .outputPathMustBeAbsolute
      )
    }

    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    XCTAssertThrowsError(try HostViewerConcurrencyEvidenceWriter(
      outputURL: fixture.output.deletingPathExtension()
        .appendingPathExtension("json"),
      identity: identity
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .outputMustBeJSONLines
      )
    }

    let missing = fixture.directory
      .appendingPathComponent("missing", isDirectory: true)
      .appendingPathComponent("events.jsonl")
    XCTAssertThrowsError(try HostViewerConcurrencyEvidenceWriter(
      outputURL: missing,
      identity: identity
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .outputParentMustExist
      )
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o777))],
      ofItemAtPath: fixture.directory.path
    )
    XCTAssertThrowsError(try makeWriter(fixture.output, role: .application)) {
      error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .outputPathIsUnsafe
      )
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: fixture.directory.path
    )

    let target = fixture.directory.appendingPathComponent(
      "target", isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: target,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    let link = fixture.directory.appendingPathComponent(
      "linked", isDirectory: true
    )
    try FileManager.default.createSymbolicLink(
      at: link,
      withDestinationURL: target
    )
    XCTAssertThrowsError(try HostViewerConcurrencyEvidenceWriter(
      outputURL: link.appendingPathComponent("events.jsonl"),
      identity: identity
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .outputPathIsUnsafe
      )
    }

    _ = try makeWriter(fixture.output, role: .application)
    XCTAssertThrowsError(try makeWriter(fixture.output, role: .application)) {
      error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .outputAlreadyExists
      )
    }
  }

  func testInvalidIdentityRoleEventTimingAndLifecycleFailClosed() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var invalidIdentity = processIdentity(role: .hostAgent)
    invalidIdentity = HostViewerConcurrencyProcessIdentity(
      role: invalidIdentity.role,
      processID: 1,
      processStartIdentitySHA256: invalidIdentity.processStartIdentitySHA256,
      buildIdentitySHA256: invalidIdentity.buildIdentitySHA256,
      scenarioCorrelationSHA256: invalidIdentity.scenarioCorrelationSHA256
    )
    XCTAssertThrowsError(try HostViewerConcurrencyEvidenceWriter(
      outputURL: fixture.output,
      identity: invalidIdentity
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidProcessIdentity
      )
    }

    let writer = try makeWriter(fixture.output, role: .hostAgent)
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    XCTAssertThrowsError(try writer.record(
      .host(hostObservation(state: .readyZeroInbound, selfObserved: true)),
      capturedAt: base,
      monotonicNanoseconds: 100
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidLifecycle
      )
    }
    XCTAssertEqual(try writer.record(
      .processStarted,
      capturedAt: base,
      monotonicNanoseconds: 100
    ), 1)
    XCTAssertThrowsError(try writer.record(
      .processStarted,
      capturedAt: base.addingTimeInterval(1),
      monotonicNanoseconds: 200
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidLifecycle
      )
    }
    XCTAssertThrowsError(try writer.record(
      .viewer(HostViewerConcurrencyViewerObservation(
        state: .starting,
        sessionEpoch: 1,
        transitionGeneration: 0
      )),
      capturedAt: base.addingTimeInterval(1),
      monotonicNanoseconds: 200
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidEvent
      )
    }
    XCTAssertThrowsError(try writer.record(
      .host(hostObservation(
        state: .disconnected,
        selfObserved: true,
        transitionGeneration: 0
      )),
      capturedAt: base.addingTimeInterval(1),
      monotonicNanoseconds: 200
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidEvent
      )
    }
    XCTAssertThrowsError(try writer.record(
      .host(hostObservation(state: .readyZeroInbound, selfObserved: true)),
      capturedAt: base.addingTimeInterval(1),
      monotonicNanoseconds: 100
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidTiming
      )
    }
    XCTAssertEqual(try writer.record(
      .processTerminating,
      capturedAt: base.addingTimeInterval(2),
      monotonicNanoseconds: 300
    ), 2)
    XCTAssertThrowsError(try writer.record(
      .host(hostObservation(state: .readyZeroInbound, selfObserved: true)),
      capturedAt: base.addingTimeInterval(3),
      monotonicNanoseconds: 400
    )) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidLifecycle
      )
    }
    XCTAssertEqual(try readRecords(fixture.output).count, 2)
  }

  func testHostAgentSelfObservationMustMatchWriterIdentity() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output, role: .hostAgent)
    _ = try writer.record(.processStarted)

    XCTAssertThrowsError(try writer.record(.host(hostObservation(
      state: .readyZeroInbound,
      selfObserved: false
    )))) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidEvent
      )
    }
    let zeroBoot = HostViewerConcurrencyHostObservation(
      state: .readyZeroInbound,
      hostInstanceScopeSHA256: hostDigest(hostRaw),
      agentBootID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
      configRevision: 3,
      hostAgentProcessID: 202,
      hostAgentProcessStartIdentitySHA256: processStartDigest(agentStartRaw),
      hostAgentBuildIdentitySHA256: buildDigest(buildRaw),
      transitionGeneration: 0
    )
    XCTAssertThrowsError(try writer.record(.host(zeroBoot))) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .invalidEvent
      )
    }
  }

  func testConcurrentCallbacksReceiveOneContiguousSequence() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output, role: .application)
    _ = try writer.record(.processStarted)
    let group = DispatchGroup()
    let failures = FailureCollector()

    for _ in 0..<64 {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async {
        defer { group.leave() }
        do {
          try writer.record(.host(self.hostObservation(
            state: .readyZeroInbound
          )))
        } catch {
          failures.append(error)
        }
      }
    }
    XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
    XCTAssertEqual(failures.snapshot().count, 0)
    _ = try writer.record(.processTerminating)

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 66)
    XCTAssertEqual(
      records.compactMap { $0["sequence"] as? Int },
      Array(1...66)
    )
    let monotonic = records.compactMap {
      ($0["monotonicNanoseconds"] as? NSNumber)?.uint64Value
    }
    XCTAssertTrue(
      zip(monotonic, monotonic.dropFirst()).allSatisfy {
        pair in pair.0 < pair.1
      }
    )
  }

  func testWriterIsBoundedAndKeepsOriginalFileHandleAfterReplacement() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = try makeWriter(fixture.output, role: .application)
    _ = try writer.record(.processStarted)
    for _ in 2...HostViewerConcurrencyEvidenceWriter.maximumRecordCount {
      _ = try writer.record(.host(hostObservation(state: .readyZeroInbound)))
    }
    XCTAssertThrowsError(try writer.record(.processTerminating)) { error in
      XCTAssertEqual(
        error as? HostViewerConcurrencyEvidenceError,
        .recordCapacityExceeded
      )
    }

    let replacementFixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: replacementFixture.directory) }
    let replacementWriter = try makeWriter(
      replacementFixture.output,
      role: .application
    )
    _ = try replacementWriter.record(.processStarted)
    try FileManager.default.removeItem(at: replacementFixture.output)
    let replacement = Data("replacement\n".utf8)
    try replacement.write(
      to: replacementFixture.output,
      options: .withoutOverwriting
    )
    _ = try replacementWriter.record(.host(
      hostObservation(state: .readyZeroInbound)
    ))
    XCTAssertEqual(try Data(contentsOf: replacementFixture.output), replacement)
  }

  private func processIdentity(
    role: HostViewerConcurrencyProcessRole
  ) -> HostViewerConcurrencyProcessIdentity {
    HostViewerConcurrencyProcessIdentity(
      role: role,
      processID: role == .application ? 101 : 202,
      processStartIdentitySHA256: processStartDigest(
        role == .application ? appStartRaw : agentStartRaw
      ),
      buildIdentitySHA256: buildDigest(buildRaw),
      scenarioCorrelationSHA256: scenarioDigest(scenarioRaw)
    )
  }

  private func hostObservation(
    state: HostViewerConcurrencyHostState,
    selfObserved: Bool = false,
    transitionGeneration: UInt64 = 0
  ) -> HostViewerConcurrencyHostObservation {
    HostViewerConcurrencyHostObservation(
      state: state,
      hostInstanceScopeSHA256: hostDigest(hostRaw),
      agentBootID: agentBootID,
      configRevision: 3,
      hostAgentProcessID: selfObserved ? 202 : 303,
      hostAgentProcessStartIdentitySHA256: processStartDigest(
        selfObserved ? agentStartRaw : "observed-agent-start-marker"
      ),
      hostAgentBuildIdentitySHA256: buildDigest(
        selfObserved ? buildRaw : "observed-agent-build"
      ),
      transitionGeneration: transitionGeneration
    )
  }

  private func makeWriter(
    _ output: URL,
    role: HostViewerConcurrencyProcessRole
  ) throws -> HostViewerConcurrencyEvidenceWriter {
    try HostViewerConcurrencyEvidenceWriter(
      outputURL: output,
      identity: processIdentity(role: role)
    )
  }

  private func processStartDigest(_ raw: String) -> String {
    HostViewerConcurrencyEvidenceDigest.processStartIdentity(raw)!
  }

  private func buildDigest(_ raw: String) -> String {
    HostViewerConcurrencyEvidenceDigest.buildIdentity(raw)!
  }

  private func hostDigest(_ raw: String) -> String {
    HostViewerConcurrencyEvidenceDigest.hostInstanceScope(raw)!
  }

  private func scenarioDigest(_ raw: String) -> String {
    HostViewerConcurrencyEvidenceDigest.scenarioCorrelation(raw)!
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
        "farpane-host-viewer-concurrency-tests",
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
    return (root, root.appendingPathComponent("events.jsonl"))
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
