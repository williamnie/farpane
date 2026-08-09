import Darwin
import Dispatch
import Foundation

public enum HostViewerConcurrencyEvidenceProcessStatus:
  Equatable,
  Sendable
{
  case idle
  case configuring
  case disabled
  case active
  case unavailable
  case terminating
  case terminated
}

public struct HostViewerConcurrencyEvidenceProcessSnapshot:
  Equatable,
  Sendable
{
  public let status: HostViewerConcurrencyEvidenceProcessStatus
  public let processStartedRecords: UInt64
  public let processTerminatingRecords: UInt64
  public let hostRecords: UInt64
  public let hostTransitionGeneration: UInt64
  public let lastHostSourceGeneration: UInt64?
  public let viewerRecords: UInt64
  public let activeViewerSessionEpoch: UInt64?
  public let viewerTransitionGeneration: UInt64
  public let configurationFailures: UInt64
  public let recordFailures: UInt64

  public init(
    status: HostViewerConcurrencyEvidenceProcessStatus,
    processStartedRecords: UInt64,
    processTerminatingRecords: UInt64,
    hostRecords: UInt64 = 0,
    hostTransitionGeneration: UInt64 = 0,
    lastHostSourceGeneration: UInt64? = nil,
    viewerRecords: UInt64 = 0,
    activeViewerSessionEpoch: UInt64? = nil,
    viewerTransitionGeneration: UInt64 = 0,
    configurationFailures: UInt64,
    recordFailures: UInt64
  ) {
    self.status = status
    self.processStartedRecords = processStartedRecords
    self.processTerminatingRecords = processTerminatingRecords
    self.hostRecords = hostRecords
    self.hostTransitionGeneration = hostTransitionGeneration
    self.lastHostSourceGeneration = lastHostSourceGeneration
    self.viewerRecords = viewerRecords
    self.activeViewerSessionEpoch = activeViewerSessionEpoch
    self.viewerTransitionGeneration = viewerTransitionGeneration
    self.configurationFailures = configurationFailures
    self.recordFailures = recordFailures
  }
}

/// Best-effort process owner for V1 coexistence evidence.
///
/// Output is default-off. When explicitly enabled, the owner derives the
/// current process start/build/scenario digests, creates one role-bound writer,
/// and records the two process-lifetime edges. Configuration or write failure
/// only disables evidence and can never become an App or HostAgent lifecycle
/// dependency.
public final class HostViewerConcurrencyEvidenceProcessOwner:
  @unchecked Sendable
{
  private enum ViewerSessionState: Equatable {
    case starting
    case streaming
    case disconnected(generation: UInt64)
    case recovered(generation: UInt64)

    var transitionGeneration: UInt64 {
      switch self {
      case .starting, .streaming:
        return 0
      case .disconnected(let generation), .recovered(let generation):
        return generation
      }
    }
  }

  private struct ViewerSession: Equatable {
    let epoch: UInt64
    let state: ViewerSessionState
  }

  private struct PreparedViewerTransition<Result> {
    let observation: HostViewerConcurrencyViewerObservation
    let nextSession: ViewerSession?
    let committedEpoch: UInt64
    let result: Result
  }

  private struct HostObservationScope: Equatable {
    let hostInstanceScopeSHA256: String
    let agentBootID: UUID
    let configRevision: UInt64
    let agentBuildIdentitySHA256: String
  }

  private enum HostSessionState: Equatable {
    case ready
    case active
    case disconnected(generation: UInt64)
    case recoveredReady(generation: UInt64)
    case recoveredActive(generation: UInt64)

    var runtimeState: HostViewerConcurrencyHostState {
      switch self {
      case .ready, .recoveredReady:
        return .readyZeroInbound
      case .active, .recoveredActive:
        return .inboundMediaActive
      case .disconnected:
        return .disconnected
      }
    }

    var evidenceState: HostViewerConcurrencyHostState {
      switch self {
      case .ready: return .readyZeroInbound
      case .active: return .inboundMediaActive
      case .disconnected: return .disconnected
      case .recoveredReady: return .recoveredReadyZeroInbound
      case .recoveredActive: return .recoveredInboundMediaActive
      }
    }

    var transitionGeneration: UInt64 {
      switch self {
      case .ready, .active:
        return 0
      case .disconnected(let generation),
           .recoveredReady(let generation),
           .recoveredActive(let generation):
        return generation
      }
    }
  }

  private struct HostSession: Equatable {
    let scope: HostObservationScope
    let sourceGeneration: UInt64
    let state: HostSessionState?
  }

  private enum PreparedHostMutation {
    case watermark(HostSession)
    case record(
      observation: HostViewerConcurrencyHostObservation,
      nextSession: HostSession
    )
  }

  public static let scenarioEnvironmentKey =
    "FARPANE_HOST_VIEWER_CONCURRENCY_SCENARIO"

  private let condition = NSCondition()
  private let processID: @Sendable () -> Int32
  private let processStartIdentity: @Sendable (Int32) -> String?
  private let buildIdentity: @Sendable () -> String?
  private let wallClock: @Sendable () -> Date
  private let monotonicNanoseconds: @Sendable () -> UInt64
  private var status: HostViewerConcurrencyEvidenceProcessStatus = .idle
  private var writer: HostViewerConcurrencyEvidenceWriter?
  private var configuredRole: HostViewerConcurrencyProcessRole?
  private var configuredIdentity: HostViewerConcurrencyProcessIdentity?
  private var configurationInFlight = false
  private var recordInFlight = false
  private var processStartedRecords: UInt64 = 0
  private var processTerminatingRecords: UInt64 = 0
  private var hostRecords: UInt64 = 0
  private var hostSession: HostSession?
  private var viewerRecords: UInt64 = 0
  private var committedViewerSessionEpoch: UInt64 = 0
  private var viewerSession: ViewerSession?
  private var configurationFailures: UInt64 = 0
  private var recordFailures: UInt64 = 0

  public convenience init() {
    self.init(
      processID: { getpid() },
      processStartIdentity: nil,
      buildIdentity: {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      },
      wallClock: { Date() },
      monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
    )
  }

  init(
    processID: @escaping @Sendable () -> Int32,
    processStartIdentity: (@Sendable (Int32) -> String?)?,
    buildIdentity: @escaping @Sendable () -> String?,
    wallClock: @escaping @Sendable () -> Date = { Date() },
    monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    }
  ) {
    self.processID = processID
    self.processStartIdentity = processStartIdentity ?? {
      Self.currentProcessStartIdentity(processID: $0)
    }
    self.buildIdentity = buildIdentity
    self.wallClock = wallClock
    self.monotonicNanoseconds = monotonicNanoseconds
  }

  deinit {
    _ = terminateAndWait()
  }

  public func snapshot() -> HostViewerConcurrencyEvidenceProcessSnapshot {
    condition.lock()
    defer { condition.unlock() }
    return HostViewerConcurrencyEvidenceProcessSnapshot(
      status: status,
      processStartedRecords: processStartedRecords,
      processTerminatingRecords: processTerminatingRecords,
      hostRecords: hostRecords,
      hostTransitionGeneration:
        hostSession?.state?.transitionGeneration ?? 0,
      lastHostSourceGeneration: hostSession?.sourceGeneration,
      viewerRecords: viewerRecords,
      activeViewerSessionEpoch: viewerSession?.epoch,
      viewerTransitionGeneration:
        viewerSession?.state.transitionGeneration ?? 0,
      configurationFailures: configurationFailures,
      recordFailures: recordFailures
    )
  }

  /// Configures exactly once for the App role. A missing output key reaches
  /// `disabled` without consulting any other identity/configuration source.
  @discardableResult
  public func configureApplication(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> Bool {
    configure(
      role: .application,
      explicitBuildIdentity: nil,
      environment: environment,
      fileManager: fileManager
    )
  }

  /// Configures exactly once for the HostAgent role. The already-preflighted
  /// Agent build identity is consumed directly instead of rediscovering it
  /// from process-global bundle state. Evidence remains default-off and
  /// best-effort.
  @discardableResult
  public func configureHostAgent(
    expectedAgentBuildID: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> Bool {
    configure(
      role: .hostAgent,
      explicitBuildIdentity: expectedAgentBuildID,
      environment: environment,
      fileManager: fileManager
    )
  }

  private func configure(
    role: HostViewerConcurrencyProcessRole,
    explicitBuildIdentity: String?,
    environment: [String: String],
    fileManager: FileManager
  ) -> Bool {
    condition.lock()
    guard status == .idle else {
      condition.unlock()
      return false
    }
    guard environment[
      HostViewerConcurrencyEvidenceWriter.outputEnvironmentKey
    ] != nil else {
      status = .disabled
      condition.broadcast()
      condition.unlock()
      return true
    }
    status = .configuring
    configurationInFlight = true
    condition.unlock()

    let configuredWriter: HostViewerConcurrencyEvidenceWriter?
    let configured: Bool
    let resolvedBuildIdentity = explicitBuildIdentity ?? buildIdentity()
    if let scenario = environment[Self.scenarioEnvironmentKey],
       let processStart = resolvedProcessStartIdentity(),
       let build = resolvedBuildIdentity,
       let processStartDigest =
         HostViewerConcurrencyEvidenceDigest.processStartIdentity(
           processStart.raw
         ),
       let buildDigest = HostViewerConcurrencyEvidenceDigest.buildIdentity(
         build
       ),
       let scenarioDigest =
         HostViewerConcurrencyEvidenceDigest.scenarioCorrelation(scenario)
    {
      let identity = HostViewerConcurrencyProcessIdentity(
        role: role,
        processID: processStart.processID,
        processStartIdentitySHA256: processStartDigest,
        buildIdentitySHA256: buildDigest,
        scenarioCorrelationSHA256: scenarioDigest
      )
      do {
        let candidate = try HostViewerConcurrencyEvidenceWriter.configured(
          environment: environment,
          identity: identity,
          fileManager: fileManager
        )
        if let candidate {
          try candidate.record(
            .processStarted,
            capturedAt: wallClock(),
            monotonicNanoseconds: monotonicNanoseconds()
          )
          configuredWriter = candidate
          configured = true
        } else {
          configuredWriter = nil
          configured = false
        }
      } catch {
        configuredWriter = nil
        configured = false
      }
    } else {
      configuredWriter = nil
      configured = false
    }

    condition.lock()
    configurationInFlight = false
    if configured, let configuredWriter {
      writer = configuredWriter
      configuredRole = role
      configuredIdentity = configuredWriter.identitySnapshot
      processStartedRecords = 1
      status = .active
    } else {
      incrementSaturating(&configurationFailures)
      status = .unavailable
    }
    condition.broadcast()
    let accepted = status == .active
    condition.unlock()
    return accepted
  }

  /// Normalizes one authoritative HostAgent runtime observation. Callers may
  /// submit only ready-zero, inbound-active or disconnected plus a strictly
  /// increasing source generation. Recovery generations are owner-derived.
  /// Invalid, duplicate, stale or foreign-scope input is ignored without
  /// disabling evidence.
  @discardableResult
  public func observeHostAgentRuntimeState(
    state: HostViewerConcurrencyHostState,
    hostInstanceID: String,
    agentBootID: UUID,
    configRevision: UInt64,
    agentBuildID: String,
    sourceGeneration: UInt64
  ) -> Bool {
    guard let hostScopeDigest =
      HostViewerConcurrencyEvidenceDigest.hostInstanceScope(hostInstanceID),
      let agentBuildDigest =
        HostViewerConcurrencyEvidenceDigest.buildIdentity(agentBuildID),
      configRevision > 0,
      sourceGeneration > 0,
      agentBootID.uuidString
        != "00000000-0000-0000-0000-000000000000",
      state == .readyZeroInbound
        || state == .inboundMediaActive
        || state == .disconnected
    else { return false }
    let scope = HostObservationScope(
      hostInstanceScopeSHA256: hostScopeDigest,
      agentBootID: agentBootID,
      configRevision: configRevision,
      agentBuildIdentitySHA256: agentBuildDigest
    )

    condition.lock()
    while status == .active && recordInFlight {
      condition.wait()
    }
    guard status == .active,
          configuredRole == .hostAgent,
          let writer,
          let configuredIdentity,
          agentBuildDigest == configuredIdentity.buildIdentitySHA256
    else {
      condition.unlock()
      return false
    }
    guard let mutation = prepareHostMutation(
      runtimeState: state,
      sourceGeneration: sourceGeneration,
      scope: scope,
      current: hostSession,
      processIdentity: configuredIdentity
    ) else {
      condition.unlock()
      return false
    }
    switch mutation {
    case .watermark(let nextSession):
      hostSession = nextSession
      condition.unlock()
      return false
    case .record:
      break
    }
    guard case .record(let observation, let nextSession) = mutation else {
      condition.unlock()
      return false
    }
    recordInFlight = true
    condition.unlock()

    let recorded: Bool
    do {
      try writer.record(
        .host(observation),
        capturedAt: wallClock(),
        monotonicNanoseconds: monotonicNanoseconds()
      )
      recorded = true
    } catch {
      recorded = false
    }

    condition.lock()
    recordInFlight = false
    if recorded {
      hostSession = nextSession
      incrementSaturating(&hostRecords)
    } else if status == .active {
      incrementSaturating(&recordFailures)
      self.writer = nil
      status = .unavailable
    }
    condition.broadcast()
    condition.unlock()
    return recorded
  }

  private func prepareHostMutation(
    runtimeState: HostViewerConcurrencyHostState,
    sourceGeneration: UInt64,
    scope: HostObservationScope,
    current: HostSession?,
    processIdentity: HostViewerConcurrencyProcessIdentity
  ) -> PreparedHostMutation? {
    if let current {
      guard current.scope == scope,
            sourceGeneration > current.sourceGeneration
      else { return nil }
      if current.state?.runtimeState == runtimeState
          || current.state == nil && runtimeState == .disconnected
      {
        return .watermark(HostSession(
          scope: scope,
          sourceGeneration: sourceGeneration,
          state: current.state
        ))
      }
    }

    let nextState: HostSessionState?
    switch (current?.state, runtimeState) {
    case (nil, .readyZeroInbound):
      nextState = .ready
    case (nil, .inboundMediaActive):
      nextState = .active
    case (nil, .disconnected):
      return .watermark(HostSession(
        scope: scope,
        sourceGeneration: sourceGeneration,
        state: nil
      ))
    case (.ready, .inboundMediaActive):
      nextState = .active
    case (.active, .readyZeroInbound):
      nextState = .ready
    case (.ready, .disconnected), (.active, .disconnected):
      nextState = .disconnected(generation: 1)
    case (.disconnected(let generation), .readyZeroInbound):
      nextState = .recoveredReady(generation: generation)
    case (.disconnected(let generation), .inboundMediaActive):
      nextState = .recoveredActive(generation: generation)
    case (.recoveredActive(let generation), .readyZeroInbound):
      nextState = .recoveredReady(generation: generation)
    case (.recoveredReady(let generation), .inboundMediaActive):
      nextState = .recoveredActive(generation: generation)
    case (.recoveredReady(let generation), .disconnected),
         (.recoveredActive(let generation), .disconnected):
      guard generation < UInt64.max else { return nil }
      nextState = .disconnected(generation: generation + 1)
    default:
      return nil
    }
    guard let nextState else { return nil }
    let observation = HostViewerConcurrencyHostObservation(
      state: nextState.evidenceState,
      hostInstanceScopeSHA256: scope.hostInstanceScopeSHA256,
      agentBootID: scope.agentBootID,
      configRevision: scope.configRevision,
      hostAgentProcessID: processIdentity.processID,
      hostAgentProcessStartIdentitySHA256:
        processIdentity.processStartIdentitySHA256,
      hostAgentBuildIdentitySHA256: scope.agentBuildIdentitySHA256,
      transitionGeneration: nextState.transitionGeneration
    )
    return .record(
      observation: observation,
      nextSession: HostSession(
        scope: scope,
        sourceGeneration: sourceGeneration,
        state: nextState
      )
    )
  }

  /// Starts one live Viewer evidence session and returns its process-local,
  /// monotonically increasing epoch. Missing/failed evidence returns nil and
  /// must never prevent the underlying Viewer connection attempt.
  @discardableResult
  public func beginViewerSession() -> UInt64? {
    performViewerTransition { currentSession, committedEpoch in
      guard currentSession == nil, committedEpoch < UInt64.max else {
        return nil
      }
      let epoch = committedEpoch + 1
      return PreparedViewerTransition(
        observation: HostViewerConcurrencyViewerObservation(
          state: .starting,
          sessionEpoch: epoch,
          transitionGeneration: 0
        ),
        nextSession: ViewerSession(epoch: epoch, state: .starting),
        committedEpoch: epoch,
        result: epoch
      )
    }
  }

  /// Accepts only the exact current session's Rust-authoritative streaming
  /// edge. Streaming after a recorded disconnect is the only recovery path.
  @discardableResult
  public func observeViewerStreaming(sessionEpoch: UInt64) -> Bool {
    performViewerTransition { currentSession, committedEpoch in
      guard let currentSession,
            currentSession.epoch == sessionEpoch
      else { return nil }
      let observation: HostViewerConcurrencyViewerObservation
      let nextState: ViewerSessionState
      switch currentSession.state {
      case .starting:
        observation = HostViewerConcurrencyViewerObservation(
          state: .authenticatedStreaming,
          sessionEpoch: sessionEpoch,
          transitionGeneration: 0
        )
        nextState = .streaming
      case .disconnected(let generation):
        observation = HostViewerConcurrencyViewerObservation(
          state: .recoveredStreaming,
          sessionEpoch: sessionEpoch,
          transitionGeneration: generation
        )
        nextState = .recovered(generation: generation)
      case .streaming, .recovered:
        return nil
      }
      return PreparedViewerTransition(
        observation: observation,
        nextSession: ViewerSession(
          epoch: sessionEpoch,
          state: nextState
        ),
        committedEpoch: committedEpoch,
        result: true
      )
    } ?? false
  }

  /// Maps one exact terminal Core edge. Pre-stream failures stop the attempt;
  /// an established/recovered stream records a disconnect and remains
  /// eligible only for a real same-epoch streaming recovery callback.
  @discardableResult
  public func observeViewerTerminal(sessionEpoch: UInt64) -> Bool {
    performViewerTransition { currentSession, committedEpoch in
      guard let currentSession,
            currentSession.epoch == sessionEpoch
      else { return nil }
      let observation: HostViewerConcurrencyViewerObservation
      let nextSession: ViewerSession?
      switch currentSession.state {
      case .starting:
        observation = HostViewerConcurrencyViewerObservation(
          state: .stopped,
          sessionEpoch: sessionEpoch,
          transitionGeneration: 0
        )
        nextSession = nil
      case .streaming:
        observation = HostViewerConcurrencyViewerObservation(
          state: .disconnected,
          sessionEpoch: sessionEpoch,
          transitionGeneration: 1
        )
        nextSession = ViewerSession(
          epoch: sessionEpoch,
          state: .disconnected(generation: 1)
        )
      case .recovered(let generation) where generation < UInt64.max:
        let nextGeneration = generation + 1
        observation = HostViewerConcurrencyViewerObservation(
          state: .disconnected,
          sessionEpoch: sessionEpoch,
          transitionGeneration: nextGeneration
        )
        nextSession = ViewerSession(
          epoch: sessionEpoch,
          state: .disconnected(generation: nextGeneration)
        )
      case .disconnected, .recovered:
        return nil
      }
      return PreparedViewerTransition(
        observation: observation,
        nextSession: nextSession,
        committedEpoch: committedEpoch,
        result: true
      )
    } ?? false
  }

  /// Records App-owned teardown before disconnecting Core. This closes any
  /// exact current session, including a session already observed disconnected.
  @discardableResult
  public func stopViewerSession(sessionEpoch: UInt64) -> Bool {
    performViewerTransition { currentSession, committedEpoch in
      guard currentSession?.epoch == sessionEpoch else { return nil }
      return PreparedViewerTransition(
        observation: HostViewerConcurrencyViewerObservation(
          state: .stopped,
          sessionEpoch: sessionEpoch,
          transitionGeneration: 0
        ),
        nextSession: nil,
        committedEpoch: committedEpoch,
        result: true
      )
    } ?? false
  }

  /// Records the terminal App edge at most once and releases the writer.
  /// Callers deliberately ignore the return value so evidence cannot alter a
  /// product decision or the App's exit status.
  @discardableResult
  public func terminateAndWait() -> Bool {
    condition.lock()
    while configurationInFlight || status == .configuring {
      condition.wait()
    }
    while status == .active && recordInFlight {
      condition.wait()
    }
    switch status {
    case .idle, .disabled:
      status = .terminated
      viewerSession = nil
      condition.broadcast()
      condition.unlock()
      return true
    case .unavailable:
      status = .terminated
      viewerSession = nil
      condition.broadcast()
      condition.unlock()
      return false
    case .active:
      guard let writer else {
        incrementSaturating(&recordFailures)
        status = .terminated
        viewerSession = nil
        condition.broadcast()
        condition.unlock()
        return false
      }
      status = .terminating
      recordInFlight = true
      condition.unlock()

      let recorded: Bool
      do {
        try writer.record(
          .processTerminating,
          capturedAt: wallClock(),
          monotonicNanoseconds: monotonicNanoseconds()
        )
        recorded = true
      } catch {
        recorded = false
      }

      condition.lock()
      recordInFlight = false
      self.writer = nil
      viewerSession = nil
      if recorded {
        processTerminatingRecords = 1
      } else {
        incrementSaturating(&recordFailures)
      }
      status = .terminated
      condition.broadcast()
      condition.unlock()
      return recorded
    case .terminating:
      while recordInFlight || status == .terminating {
        condition.wait()
      }
      condition.unlock()
      return false
    case .terminated:
      condition.unlock()
      return false
    case .configuring:
      condition.unlock()
      return false
    }
  }

  static func currentProcessStartIdentity(
    processID: Int32
  ) -> String? {
    guard processID > 1 else { return nil }
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let copiedSize = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        pointer,
        expectedSize
      )
    }
    guard copiedSize == expectedSize,
          info.pbi_pid == UInt32(processID),
          info.pbi_start_tvsec > 0,
          info.pbi_start_tvusec < 1_000_000
    else { return nil }
    return "pid=\(processID);sec=\(info.pbi_start_tvsec);"
      + "usec=\(info.pbi_start_tvusec)"
  }

  private func resolvedProcessStartIdentity() ->
    (processID: Int32, raw: String)?
  {
    let currentProcessID = processID()
    guard currentProcessID > 1,
          let raw = processStartIdentity(currentProcessID)
    else { return nil }
    return (currentProcessID, raw)
  }

  private func performViewerTransition<Result>(
    _ prepare: (
      ViewerSession?,
      UInt64
    ) -> PreparedViewerTransition<Result>?
  ) -> Result? {
    condition.lock()
    while status == .active && recordInFlight {
      condition.wait()
    }
    guard status == .active,
          configuredRole == .application,
          let writer,
          let transition = prepare(
            viewerSession,
            committedViewerSessionEpoch
          )
    else {
      condition.unlock()
      return nil
    }
    recordInFlight = true
    condition.unlock()

    let recorded: Bool
    do {
      try writer.record(
        .viewer(transition.observation),
        capturedAt: wallClock(),
        monotonicNanoseconds: monotonicNanoseconds()
      )
      recorded = true
    } catch {
      recorded = false
    }

    condition.lock()
    recordInFlight = false
    if recorded {
      viewerSession = transition.nextSession
      committedViewerSessionEpoch = transition.committedEpoch
      incrementSaturating(&viewerRecords)
    } else if status == .active {
      incrementSaturating(&recordFailures)
      self.writer = nil
      viewerSession = nil
      status = .unavailable
    }
    condition.broadcast()
    let result = recorded ? transition.result : nil
    condition.unlock()
    return result
  }

  private func incrementSaturating(_ value: inout UInt64) {
    if value < UInt64.max { value += 1 }
  }
}
