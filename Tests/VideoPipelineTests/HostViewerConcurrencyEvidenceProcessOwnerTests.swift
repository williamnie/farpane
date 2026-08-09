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
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: "host-private-value",
      agentBootID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      configRevision: 1,
      agentBuildID: buildRaw,
      sourceGeneration: 1
    ))
    XCTAssertEqual(owner.snapshot().status, .active)
    XCTAssertEqual(owner.snapshot().hostRecords, 0)
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

  func testHostAgentNormalizesAuthoritativeRuntimeTransitions() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let expectedAgentBuildID = "agent-preflight-build"
    let hostInstanceID = "host-private-value"
    let agentBootID = UUID(
      uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    let calls = LockedCallCounts()
    let owner = HostViewerConcurrencyEvidenceProcessOwner(
      processID: {
        calls.incrementProcessID()
        return 4_242
      },
      processStartIdentity: { _ in
        calls.incrementProcessStart()
        return self.processStartRaw
      },
      buildIdentity: {
        calls.incrementBuild()
        return "must-not-be-read"
      }
    )

    XCTAssertTrue(owner.configureHostAgent(
      expectedAgentBuildID: expectedAgentBuildID,
      environment: environment(output: fixture.output)
    ))
    XCTAssertEqual(calls.snapshot(), .init(
      processID: 1,
      processStart: 1,
      build: 0
    ))
    XCTAssertNil(owner.beginViewerSession())
    XCTAssertEqual(owner.snapshot().status, .active)
    XCTAssertEqual(owner.snapshot().recordFailures, 0)
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 0,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 1
    ))
    XCTAssertEqual(owner.snapshot().status, .active)
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .disconnected,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 1
    ))
    XCTAssertEqual(owner.snapshot().hostRecords, 0)
    XCTAssertEqual(owner.snapshot().lastHostSourceGeneration, 1)
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 2
    ))
    XCTAssertEqual(owner.snapshot().hostRecords, 1)
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 3
    ))
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .inboundMediaActive,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 2
    ))
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .inboundMediaActive,
      hostInstanceID: "foreign-host",
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 4
    ))
    XCTAssertEqual(owner.snapshot().lastHostSourceGeneration, 3)
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .inboundMediaActive,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 4
    ))
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .disconnected,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 5
    ))
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .disconnected,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 6
    ))
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .inboundMediaActive,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 7
    ))
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 8
    ))
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .disconnected,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 9
    ))
    XCTAssertTrue(owner.observeHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 10
    ))
    XCTAssertFalse(owner.observeHostAgentRuntimeState(
      state: .recoveredInboundMediaActive,
      hostInstanceID: hostInstanceID,
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: expectedAgentBuildID,
      sourceGeneration: 11
    ))
    XCTAssertEqual(owner.snapshot().hostRecords, 7)
    XCTAssertEqual(owner.snapshot().hostTransitionGeneration, 2)
    XCTAssertEqual(owner.snapshot().lastHostSourceGeneration, 10)
    XCTAssertTrue(owner.terminateAndWait())

    let records = try readRecords(fixture.output)
    XCTAssertEqual(records.count, 9)
    XCTAssertTrue(records.allSatisfy {
      $0["observerProcessRole"] as? String == "hostAgent"
        && $0["observerBuildIdentitySHA256"] as? String
          == HostViewerConcurrencyEvidenceDigest.buildIdentity(
            expectedAgentBuildID
          )
    })
    XCTAssertEqual(records.compactMap {
      ($0["event"] as? [String: Any])?["kind"] as? String
    }, [
      "processStarted",
      "hostState", "hostState", "hostState", "hostState", "hostState",
      "hostState", "hostState",
      "processTerminating",
    ])
    let hostEvents = try records[1...7].map {
      try XCTUnwrap($0["event"] as? [String: Any])
    }
    XCTAssertEqual(hostEvents.compactMap { $0["state"] as? String }, [
      "readyZeroInbound",
      "inboundMediaActive",
      "disconnected",
      "recoveredInboundMediaActive",
      "recoveredReadyZeroInbound",
      "disconnected",
      "recoveredReadyZeroInbound",
    ])
    XCTAssertEqual(
      hostEvents.compactMap { $0["transitionGeneration"] as? Int },
      [0, 0, 1, 1, 1, 2, 2]
    )
    let hostEvent = hostEvents[0]
    XCTAssertEqual(
      hostEvent["agentBootID"] as? String,
      agentBootID.uuidString.lowercased()
    )
    XCTAssertEqual(hostEvent["configRevision"] as? Int, 7)
    XCTAssertEqual(
      hostEvent["hostInstanceScopeSHA256"] as? String,
      HostViewerConcurrencyEvidenceDigest.hostInstanceScope(hostInstanceID)
    )
  }

  func testConcurrentHostSourceGenerationRecordsOneStateEdge() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = makeOwner()
    XCTAssertTrue(owner.configureHostAgent(
      expectedAgentBuildID: buildRaw,
      environment: environment(output: fixture.output)
    ))
    let results = LockedBooleanResults()
    let agentBootID = UUID(
      uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!

    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      results.append(owner.observeHostAgentRuntimeState(
        state: .readyZeroInbound,
        hostInstanceID: "host-private-value",
        agentBootID: agentBootID,
        configRevision: 1,
        agentBuildID: buildRaw,
        sourceGeneration: 1
      ))
    }

    XCTAssertEqual(results.snapshot().filter { $0 }.count, 1)
    XCTAssertEqual(owner.snapshot().hostRecords, 1)
    XCTAssertEqual(owner.snapshot().lastHostSourceGeneration, 1)
    XCTAssertTrue(owner.terminateAndWait())
    XCTAssertEqual(try readRecords(fixture.output).count, 3)
  }

  func testApplicationRecordsOnlyExactHandshakeAgentProcessIdentity() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = makeOwner()
    let agentBootID = UUID(
      uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    let agentProcessStart = String(repeating: "a", count: 64)
    XCTAssertTrue(owner.configureApplication(environment: environment(
      output: fixture.output
    )))

    XCTAssertFalse(owner.observeApplicationHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: "host-private-value",
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: "agent-build",
      agentProcessID: 4_321,
      agentProcessStartIdentitySHA256:
        String(repeating: "A", count: 64),
      sourceGeneration: 1
    ))
    XCTAssertTrue(owner.observeApplicationHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: "host-private-value",
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: "agent-build",
      agentProcessID: 4_321,
      agentProcessStartIdentitySHA256: agentProcessStart,
      sourceGeneration: 1
    ))
    XCTAssertTrue(owner.observeApplicationHostAgentRuntimeState(
      state: .disconnected,
      hostInstanceID: "host-private-value",
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: "agent-build",
      agentProcessID: 4_321,
      agentProcessStartIdentitySHA256: agentProcessStart,
      sourceGeneration: 2
    ))
    XCTAssertTrue(owner.observeApplicationHostAgentRuntimeState(
      state: .readyZeroInbound,
      hostInstanceID: "host-private-value",
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: "agent-build",
      agentProcessID: 4_321,
      agentProcessStartIdentitySHA256: agentProcessStart,
      sourceGeneration: 3
    ))
    XCTAssertFalse(owner.observeApplicationHostAgentRuntimeState(
      state: .inboundMediaActive,
      hostInstanceID: "host-private-value",
      agentBootID: agentBootID,
      configRevision: 7,
      agentBuildID: "agent-build",
      agentProcessID: 4_322,
      agentProcessStartIdentitySHA256:
        String(repeating: "b", count: 64),
      sourceGeneration: 4
    ))
    XCTAssertEqual(owner.snapshot().hostRecords, 3)
    XCTAssertEqual(owner.snapshot().lastHostSourceGeneration, 3)
    XCTAssertTrue(owner.terminateAndWait())

    let records = try readRecords(fixture.output)
    let hostEvents = records.compactMap {
      $0["event"] as? [String: Any]
    }.filter { $0["kind"] as? String == "hostState" }
    XCTAssertEqual(hostEvents.compactMap { $0["state"] as? String }, [
      "readyZeroInbound", "disconnected", "recoveredReadyZeroInbound",
    ])
    XCTAssertTrue(records.allSatisfy {
      $0["observerProcessRole"] as? String == "application"
        && $0["observerProcessID"] as? Int == 4_242
    })
    XCTAssertTrue(hostEvents.allSatisfy {
      $0["hostAgentProcessID"] as? Int == 4_321
        && $0["hostAgentProcessStartIdentitySHA256"] as? String
          == agentProcessStart
        && $0["hostAgentBuildIdentitySHA256"] as? String
          == HostViewerConcurrencyEvidenceDigest.buildIdentity("agent-build")
    })
  }

  func testHostAgentMissingOutputDoesNotResolveAnyIdentity() {
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

    XCTAssertTrue(owner.configureHostAgent(
      expectedAgentBuildID: "agent-preflight-build",
      environment: [:]
    ))
    XCTAssertEqual(calls.snapshot(), .init(
      processID: 0,
      processStart: 0,
      build: 0
    ))
    XCTAssertEqual(owner.snapshot().status, .disabled)
    XCTAssertTrue(owner.terminateAndWait())
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

  func testViewerSessionStateMachinePreservesEpochAndRecoveryGeneration() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = makeOwner()
    XCTAssertTrue(owner.configureApplication(environment: environment(
      output: fixture.output
    )))

    let firstEpoch = try XCTUnwrap(owner.beginViewerSession())
    XCTAssertEqual(firstEpoch, 1)
    XCTAssertNil(owner.beginViewerSession())
    XCTAssertTrue(owner.observeViewerStreaming(sessionEpoch: firstEpoch))
    XCTAssertFalse(owner.observeViewerStreaming(sessionEpoch: firstEpoch))
    XCTAssertTrue(owner.observeViewerTerminal(sessionEpoch: firstEpoch))
    XCTAssertFalse(owner.observeViewerTerminal(sessionEpoch: firstEpoch))
    XCTAssertTrue(owner.observeViewerStreaming(sessionEpoch: firstEpoch))
    XCTAssertTrue(owner.observeViewerTerminal(sessionEpoch: firstEpoch))
    XCTAssertTrue(owner.stopViewerSession(sessionEpoch: firstEpoch))
    XCTAssertFalse(owner.stopViewerSession(sessionEpoch: firstEpoch))

    let secondEpoch = try XCTUnwrap(owner.beginViewerSession())
    XCTAssertEqual(secondEpoch, 2)
    XCTAssertFalse(owner.observeViewerStreaming(sessionEpoch: firstEpoch))
    XCTAssertFalse(owner.observeViewerTerminal(sessionEpoch: firstEpoch))
    XCTAssertTrue(owner.observeViewerTerminal(sessionEpoch: secondEpoch))
    XCTAssertEqual(owner.snapshot(), .init(
      status: .active,
      processStartedRecords: 1,
      processTerminatingRecords: 0,
      viewerRecords: 8,
      activeViewerSessionEpoch: nil,
      viewerTransitionGeneration: 0,
      configurationFailures: 0,
      recordFailures: 0
    ))

    let viewerEvents = try readRecords(fixture.output).compactMap { record ->
      (state: String, epoch: Int, generation: Int)? in
      guard let event = record["event"] as? [String: Any],
            event["kind"] as? String == "viewerState",
            let state = event["state"] as? String,
            let epoch = event["sessionEpoch"] as? Int,
            let generation = event["transitionGeneration"] as? Int
      else { return nil }
      return (state, epoch, generation)
    }
    XCTAssertEqual(viewerEvents.map(\.state), [
      "starting",
      "authenticatedStreaming",
      "disconnected",
      "recoveredStreaming",
      "disconnected",
      "stopped",
      "starting",
      "stopped",
    ])
    XCTAssertEqual(viewerEvents.map(\.epoch), [1, 1, 1, 1, 1, 1, 2, 2])
    XCTAssertEqual(viewerEvents.map(\.generation), [0, 0, 1, 1, 2, 0, 0, 0])
  }

  func testConcurrentCoreStreamingCallbackRecordsOneStateEdge() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let owner = makeOwner()
    XCTAssertTrue(owner.configureApplication(environment: environment(
      output: fixture.output
    )))
    let sessionEpoch = try XCTUnwrap(owner.beginViewerSession())
    let results = LockedBooleanResults()

    DispatchQueue.concurrentPerform(iterations: 64) { _ in
      results.append(owner.observeViewerStreaming(
        sessionEpoch: sessionEpoch
      ))
    }

    XCTAssertEqual(results.snapshot().filter { $0 }.count, 1)
    XCTAssertEqual(owner.snapshot().viewerRecords, 2)
    XCTAssertEqual(try readRecords(fixture.output).count, 3)
  }

  func testViewerRecordFailureDisablesOnlyEvidence() throws {
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

    XCTAssertNil(owner.beginViewerSession())
    XCTAssertEqual(owner.snapshot(), .init(
      status: .unavailable,
      processStartedRecords: 1,
      processTerminatingRecords: 0,
      viewerRecords: 0,
      activeViewerSessionEpoch: nil,
      viewerTransitionGeneration: 0,
      configurationFailures: 0,
      recordFailures: 1
    ))
    XCTAssertFalse(owner.observeViewerStreaming(sessionEpoch: 1))
    XCTAssertFalse(owner.stopViewerSession(sessionEpoch: 1))
    XCTAssertEqual(try readRecords(fixture.output).count, 1)
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
