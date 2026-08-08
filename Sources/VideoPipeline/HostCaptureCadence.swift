import Foundation

public enum HostCaptureContentState: String, Equatable, Sendable {
  case idle
  case lowMotion
  case interactive
  case highMotion
}

public enum HostCapturePressureLevel: String, Equatable, Sendable {
  case none
  case moderate
  case severe
}

public enum HostCapturePressureCause: String, Equatable, Sendable {
  case thermalState
  case lowPowerMode
  case encodeInFlight
  case encodeLatency
  case consecutiveSendDrops
  case recentSendDropRate
  case encodedQueue
  case networkDelay
  case roundTripTime
  case responseDelayed
}

struct HostCapturePressureAssessment: Equatable, Sendable {
  let level: HostCapturePressureLevel
  let causes: [HostCapturePressureCause]
}

struct HostCaptureBackpressure: Equatable, Sendable {
  static let minimumEncodedQueueNearFullSamples = 3

  let encodeInFlight: Int
  let latestEncodeLatencyMS: Double?
  let recentSendOutcomeCount: Int
  let recentSendDropRate: Double
  let consecutiveSendDrops: Int
  let encodedQueueDepth: Int?
  let encodedQueueCapacity: Int?
  let consecutiveEncodedQueueNearFullSamples: Int
  let networkDelayMS: Int?
  let roundTripTimeMS: Int?
  let responseDelayedSubscribers: Int?
  let thermalState: String?
  let lowPowerModeEnabled: Bool?

  init(
    encodeInFlight: Int,
    latestEncodeLatencyMS: Double?,
    recentSendOutcomeCount: Int,
    recentSendDropRate: Double,
    consecutiveSendDrops: Int,
    encodedQueueDepth: Int? = nil,
    encodedQueueCapacity: Int? = nil,
    consecutiveEncodedQueueNearFullSamples: Int = 0,
    networkDelayMS: Int? = nil,
    roundTripTimeMS: Int? = nil,
    responseDelayedSubscribers: Int? = nil,
    thermalState: String? = nil,
    lowPowerModeEnabled: Bool? = nil
  ) {
    self.encodeInFlight = encodeInFlight
    self.latestEncodeLatencyMS = latestEncodeLatencyMS
    self.recentSendOutcomeCount = recentSendOutcomeCount
    self.recentSendDropRate = recentSendDropRate
    self.consecutiveSendDrops = consecutiveSendDrops
    self.encodedQueueDepth = encodedQueueDepth
    self.encodedQueueCapacity = encodedQueueCapacity
    self.consecutiveEncodedQueueNearFullSamples = max(
      0,
      consecutiveEncodedQueueNearFullSamples
    )
    self.networkDelayMS = networkDelayMS
    self.roundTripTimeMS = roundTripTimeMS
    self.responseDelayedSubscribers = responseDelayedSubscribers
    self.thermalState = thermalState
    self.lowPowerModeEnabled = lowPowerModeEnabled
  }

  static let clear = HostCaptureBackpressure(
    encodeInFlight: 0,
    latestEncodeLatencyMS: nil,
    recentSendOutcomeCount: 0,
    recentSendDropRate: 0,
    consecutiveSendDrops: 0,
    encodedQueueDepth: nil,
    encodedQueueCapacity: nil,
    consecutiveEncodedQueueNearFullSamples: 0,
    networkDelayMS: nil,
    roundTripTimeMS: nil,
    responseDelayedSubscribers: nil,
    thermalState: nil,
    lowPowerModeEnabled: nil
  )

  func level(maximumFramesPerSecond: Int) -> HostCapturePressureLevel {
    assessment(maximumFramesPerSecond: maximumFramesPerSecond).level
  }

  func assessment(maximumFramesPerSecond: Int) -> HostCapturePressureAssessment {
    let frameBudgetMS = 1_000 / Double(max(1, maximumFramesPerSecond))
    let hasSendWindow = recentSendOutcomeCount >= 8
    let normalizedThermalState = thermalState?.lowercased()
    let encodedQueueFull = encodedQueueDepth.flatMap { depth in
      encodedQueueCapacity.map { capacity in capacity > 0 && depth >= capacity }
    } ?? false
    let encodedQueueNearFull = encodedQueueDepth.flatMap { depth in
      encodedQueueCapacity.map { capacity in
        capacity > 0
          && depth < capacity
          && depth >= max(1, capacity - 1)
          && consecutiveEncodedQueueNearFullSamples
            >= Self.minimumEncodedQueueNearFullSamples
      }
    } ?? false
    var triggers: [(HostCapturePressureCause, HostCapturePressureLevel)] = []
    if normalizedThermalState == "critical" {
      triggers.append((.thermalState, .severe))
    } else if normalizedThermalState == "fair" || normalizedThermalState == "serious" {
      triggers.append((.thermalState, .moderate))
    }
    if lowPowerModeEnabled == true {
      triggers.append((.lowPowerMode, .moderate))
    }
    if encodeInFlight >= 4 {
      triggers.append((.encodeInFlight, .severe))
    } else if encodeInFlight >= 2 {
      triggers.append((.encodeInFlight, .moderate))
    }
    if (latestEncodeLatencyMS ?? 0) >= frameBudgetMS * 4 {
      triggers.append((.encodeLatency, .severe))
    } else if (latestEncodeLatencyMS ?? 0) >= frameBudgetMS * 2 {
      triggers.append((.encodeLatency, .moderate))
    }
    if consecutiveSendDrops >= 4 {
      triggers.append((.consecutiveSendDrops, .severe))
    } else if consecutiveSendDrops >= 2 {
      triggers.append((.consecutiveSendDrops, .moderate))
    }
    if hasSendWindow, recentSendDropRate >= 0.25 {
      triggers.append((.recentSendDropRate, .severe))
    } else if hasSendWindow, recentSendDropRate >= 0.125 {
      triggers.append((.recentSendDropRate, .moderate))
    }
    if encodedQueueFull {
      triggers.append((.encodedQueue, .severe))
    } else if encodedQueueNearFull {
      triggers.append((.encodedQueue, .moderate))
    }
    if (networkDelayMS ?? 0) >= 300 {
      triggers.append((.networkDelay, .severe))
    } else if (networkDelayMS ?? 0) >= 150 {
      triggers.append((.networkDelay, .moderate))
    }
    if (roundTripTimeMS ?? 0) >= 500 {
      triggers.append((.roundTripTime, .severe))
    } else if (roundTripTimeMS ?? 0) >= 250 {
      triggers.append((.roundTripTime, .moderate))
    }
    if (responseDelayedSubscribers ?? 0) > 0 {
      triggers.append((.responseDelayed, .severe))
    }
    let level: HostCapturePressureLevel
    if triggers.contains(where: { $0.1 == .severe }) {
      level = .severe
    } else if triggers.isEmpty {
      level = .none
    } else {
      level = .moderate
    }
    return HostCapturePressureAssessment(
      level: level,
      causes: triggers.map(\.0)
    )
  }
}

public struct HostCaptureCadenceDecision: Equatable, Sendable {
  public let contentState: HostCaptureContentState
  public let framesPerSecond: Int
  public let dirtyMetadataTrusted: Bool
  public let pressureLevel: HostCapturePressureLevel

  public init(
    contentState: HostCaptureContentState,
    framesPerSecond: Int,
    dirtyMetadataTrusted: Bool,
    pressureLevel: HostCapturePressureLevel = .none
  ) {
    self.contentState = contentState
    self.framesPerSecond = framesPerSecond
    self.dirtyMetadataTrusted = dirtyMetadataTrusted
    self.pressureLevel = pressureLevel
  }
}

enum HostCaptureCadenceEvent: Equatable, Sendable {
  case decision(HostCaptureCadenceDecision)
  case configurationSubmitted(framesPerSecond: Int)
  case configurationApplied(framesPerSecond: Int)
  case configurationFailed(framesPerSecond: Int)
  case configurationCancelled
}

/// Bounded, deterministic dirty-rect cadence policy for H2.2 (§11.3).
///
/// Promotions use the latest frame as an escape hatch from an idle cadence;
/// demotions require a full rolling window. State-specific hold thresholds and
/// a minimum dwell time prevent boundary noise from oscillating the stream.
/// Missing/non-finite metadata fails safe to high-motion content demand instead
/// of treating an unknown frame as unchanged; an active pressure cap remains
/// authoritative until its own bounded recovery gate clears.
public struct HostCaptureCadenceController: Sendable {
  private struct MotionSummary {
    let latestRatio: Double
    let averageRatio: Double
    let changedFrequency: Double
  }

  public let maximumFramesPerSecond: Int
  public let windowSize: Int
  public let minimumDwellNanoseconds: UInt64

  public private(set) var decision: HostCaptureCadenceDecision

  private var dirtyRatios: [Double] = []
  private var lastTransitionNanoseconds: UInt64
  private var pressureLevel = HostCapturePressureLevel.none
  private var pressureRecoverySamples = 0
  private var lastPressureTransitionNanoseconds: UInt64

  public init(
    maximumFramesPerSecond: Int,
    windowSize: Int = 8,
    minimumDwellTime: TimeInterval = 2,
    startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) {
    let boundedMaximum = min(240, max(1, maximumFramesPerSecond))
    self.maximumFramesPerSecond = boundedMaximum
    self.windowSize = min(120, max(2, windowSize))
    self.minimumDwellNanoseconds = UInt64(
      max(0, minimumDwellTime) * 1_000_000_000
    )
    self.decision = HostCaptureCadenceDecision(
      contentState: .highMotion,
      framesPerSecond: boundedMaximum,
      dirtyMetadataTrusted: false,
      pressureLevel: .none
    )
    self.lastTransitionNanoseconds = startedAtNanoseconds
    self.lastPressureTransitionNanoseconds = startedAtNanoseconds
  }

  @discardableResult
  public mutating func observe(
    dirtyAreaRatio: Double?,
    nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) -> HostCaptureCadenceDecision {
    observe(
      dirtyAreaRatio: dirtyAreaRatio,
      backpressure: .clear,
      nowNanoseconds: nowNanoseconds
    )
  }

  @discardableResult
  mutating func observe(
    dirtyAreaRatio: Double?,
    backpressure: HostCaptureBackpressure,
    nowNanoseconds: UInt64
  ) -> HostCaptureCadenceDecision {
    updatePressure(backpressure, nowNanoseconds: nowNanoseconds)
    guard let dirtyAreaRatio, dirtyAreaRatio.isFinite else {
      dirtyRatios.removeAll(keepingCapacity: true)
      decision = makeDecision(for: .highMotion, dirtyMetadataTrusted: false)
      lastTransitionNanoseconds = nowNanoseconds
      return decision
    }

    dirtyRatios.append(min(1, max(0, dirtyAreaRatio)))
    if dirtyRatios.count > windowSize {
      dirtyRatios.removeFirst(dirtyRatios.count - windowSize)
    }
    let summary = summarizeMotion()
    var candidate = entryState(for: summary)
    candidate = stateAfterApplyingHysteresis(candidate, summary: summary)

    let currentRank = Self.rank(of: decision.contentState)
    let candidateRank = Self.rank(of: candidate)
    if candidateRank < currentRank, dirtyRatios.count < windowSize {
      decision = makeDecision(for: decision.contentState, dirtyMetadataTrusted: true)
      return decision
    }

    let dwellElapsed = nowNanoseconds >= lastTransitionNanoseconds
      && nowNanoseconds - lastTransitionNanoseconds >= minimumDwellNanoseconds
    guard candidate == decision.contentState || dwellElapsed else {
      decision = makeDecision(for: decision.contentState, dirtyMetadataTrusted: true)
      return decision
    }
    if candidate != decision.contentState {
      lastTransitionNanoseconds = nowNanoseconds
    }
    decision = makeDecision(for: candidate, dirtyMetadataTrusted: true)
    return decision
  }

  private mutating func updatePressure(
    _ backpressure: HostCaptureBackpressure,
    nowNanoseconds: UInt64
  ) {
    let observed = backpressure.level(
      maximumFramesPerSecond: maximumFramesPerSecond
    )
    let observedRank = Self.rank(of: observed)
    let currentRank = Self.rank(of: pressureLevel)
    if observedRank > currentRank {
      pressureLevel = observed
      pressureRecoverySamples = 0
      lastPressureTransitionNanoseconds = nowNanoseconds
      return
    }
    if observedRank == currentRank {
      pressureRecoverySamples = 0
      return
    }
    pressureRecoverySamples += 1
    let dwellElapsed = nowNanoseconds >= lastPressureTransitionNanoseconds
      && nowNanoseconds - lastPressureTransitionNanoseconds >= minimumDwellNanoseconds
    if pressureRecoverySamples >= windowSize, dwellElapsed {
      pressureLevel = observed
      pressureRecoverySamples = 0
      lastPressureTransitionNanoseconds = nowNanoseconds
    }
  }

  private func summarizeMotion() -> MotionSummary {
    let latest = dirtyRatios.last ?? 0
    let total = dirtyRatios.reduce(0, +)
    let changed = dirtyRatios.reduce(0) { count, ratio in
      count + (ratio >= 0.002 ? 1 : 0)
    }
    return MotionSummary(
      latestRatio: latest,
      averageRatio: total / Double(dirtyRatios.count),
      changedFrequency: Double(changed) / Double(dirtyRatios.count)
    )
  }

  private func entryState(for summary: MotionSummary) -> HostCaptureContentState {
    if summary.latestRatio >= 0.35 || summary.averageRatio >= 0.20 {
      return .highMotion
    }
    if summary.latestRatio >= 0.08
      || summary.averageRatio >= 0.03
      || summary.changedFrequency >= 0.60 {
      return .interactive
    }
    if summary.latestRatio >= 0.005
      || summary.averageRatio >= 0.002
      || summary.changedFrequency >= 0.20 {
      return .lowMotion
    }
    return .idle
  }

  private func stateAfterApplyingHysteresis(
    _ candidate: HostCaptureContentState,
    summary: MotionSummary
  ) -> HostCaptureContentState {
    guard Self.rank(of: candidate) < Self.rank(of: decision.contentState) else {
      return candidate
    }
    if Self.rank(of: decision.contentState) >= Self.rank(of: .highMotion),
       summary.latestRatio >= 0.20 || summary.averageRatio >= 0.12 {
      return .highMotion
    }
    if Self.rank(of: decision.contentState) >= Self.rank(of: .interactive),
       summary.latestRatio >= 0.04
        || summary.averageRatio >= 0.015
        || summary.changedFrequency >= 0.35 {
      return .interactive
    }
    if Self.rank(of: decision.contentState) >= Self.rank(of: .lowMotion),
       summary.latestRatio >= 0.002
        || summary.averageRatio >= 0.001
        || summary.changedFrequency >= 0.10 {
      return .lowMotion
    }
    return candidate
  }

  private func makeDecision(
    for state: HostCaptureContentState,
    dirtyMetadataTrusted: Bool
  ) -> HostCaptureCadenceDecision {
    HostCaptureCadenceDecision(
      contentState: state,
      framesPerSecond: min(
        framesPerSecond(for: state),
        pressureFramesPerSecondCap
      ),
      dirtyMetadataTrusted: dirtyMetadataTrusted,
      pressureLevel: pressureLevel
    )
  }

  private var pressureFramesPerSecondCap: Int {
    switch pressureLevel {
    case .none: return maximumFramesPerSecond
    case .moderate: return min(maximumFramesPerSecond, 15)
    case .severe: return min(maximumFramesPerSecond, 5)
    }
  }

  private func framesPerSecond(for state: HostCaptureContentState) -> Int {
    let tier: Int
    switch state {
    case .idle: tier = 3
    case .lowMotion: tier = 12
    case .interactive: tier = 30
    case .highMotion: tier = 60
    }
    return min(maximumFramesPerSecond, tier)
  }

  private static func rank(of state: HostCaptureContentState) -> Int {
    switch state {
    case .idle: return 0
    case .lowMotion: return 1
    case .interactive: return 2
    case .highMotion: return 3
    }
  }

  private static func rank(of level: HostCapturePressureLevel) -> Int {
    switch level {
    case .none: return 0
    case .moderate: return 1
    case .severe: return 2
    }
  }
}
