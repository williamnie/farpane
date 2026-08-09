import CryptoKit
import Dispatch
import Foundation

public enum HostRecoveryTransitionEvidenceProcessStatus:
  Equatable,
  Sendable
{
  case idle
  case configuring
  case disabled
  case active
  case unavailable
  case cancelling
  case cancelled
}

public struct HostRecoveryTransitionEvidenceProcessSnapshot:
  Equatable,
  Sendable
{
  public let status: HostRecoveryTransitionEvidenceProcessStatus
  public let completedRecords: UInt64
  public let configurationFailures: UInt64
  public let recordFailures: UInt64
}

/// Process-lifetime, best-effort owner for recovery acceptance evidence.
///
/// Raw Host/build identity is accepted only long enough to derive two
/// domain-separated SHA-256 digests. Evidence configuration or append failure
/// permanently disables this owner but never changes the caller's recovery
/// result, runtime lifetime, readiness, or termination policy.
public final class HostRecoveryTransitionEvidenceProcessOwner:
  @unchecked Sendable
{
  private struct SleepWakeAcceptance {
    let recoveryEpoch: UInt64
    let acceptedAt: Date
    let acceptedMonotonicNanoseconds: UInt64
  }

  private struct NetworkPathAcceptance {
    let pathGeneration: UInt64
    let recoveryEpoch: UInt64
    let acceptedAt: Date
    let acceptedMonotonicNanoseconds: UInt64
  }

  private static let maximumIdentityUTF8Bytes = 512
  private static let scopeDigestDomain =
    "farpane.host-recovery.scope.v1"
  private static let buildDigestDomain =
    "farpane.host-recovery.build.v1"

  private let condition = NSCondition()
  private let wallClock: @Sendable () -> Date
  private let monotonicNanoseconds: @Sendable () -> UInt64
  private var status: HostRecoveryTransitionEvidenceProcessStatus = .idle
  private var writer: HostRecoveryTransitionEvidenceWriter?
  private var pendingSleepWakeAcceptance: SleepWakeAcceptance?
  private var pendingNetworkPathAcceptance: NetworkPathAcceptance?
  private var sleepWakeAcceptanceInFlight = false
  private var networkPathAcceptanceInFlight = false
  private var configurationInFlight = false
  private var recordInFlight = false
  private var completedRecords: UInt64 = 0
  private var configurationFailures: UInt64 = 0
  private var recordFailures: UInt64 = 0

  public init(
    wallClock: @escaping @Sendable () -> Date = { Date() },
    monotonicNanoseconds: @escaping @Sendable () -> UInt64 = {
      DispatchTime.now().uptimeNanoseconds
    }
  ) {
    self.wallClock = wallClock
    self.monotonicNanoseconds = monotonicNanoseconds
  }

  deinit {
    cancelAndWait()
  }

  public func snapshot() -> HostRecoveryTransitionEvidenceProcessSnapshot {
    condition.lock()
    defer { condition.unlock() }
    return HostRecoveryTransitionEvidenceProcessSnapshot(
      status: status,
      completedRecords: completedRecords,
      configurationFailures: configurationFailures,
      recordFailures: recordFailures
    )
  }

  /// Configures at most once. A missing output environment key is an explicit
  /// disabled state, while malformed identity/path or writer creation failure
  /// becomes unavailable. Neither result is a Host startup failure.
  @discardableResult
  public func configure(
    hostInstanceID: String,
    buildIdentity: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> Bool {
    condition.lock()
    guard status == .idle else {
      condition.unlock()
      return false
    }
    status = .configuring
    configurationInFlight = true
    condition.unlock()

    let configuredWriter: HostRecoveryTransitionEvidenceWriter?
    let configurationSucceeded: Bool
    if let scopeDigest = Self.digest(
      domain: Self.scopeDigestDomain,
      identity: hostInstanceID
    ), let buildDigest = Self.digest(
      domain: Self.buildDigestDomain,
      identity: buildIdentity
    ) {
      do {
        configuredWriter = try HostRecoveryTransitionEvidenceWriter.configured(
          environment: environment,
          hostInstanceScopeSHA256: scopeDigest,
          buildIdentitySHA256: buildDigest,
          fileManager: fileManager
        )
        configurationSucceeded = true
      } catch {
        configuredWriter = nil
        configurationSucceeded = false
      }
    } else {
      configuredWriter = nil
      configurationSucceeded = false
    }

    condition.lock()
    configurationInFlight = false
    if status == .configuring {
      if configurationSucceeded {
        writer = configuredWriter
        status = configuredWriter == nil ? .disabled : .active
      } else {
        incrementSaturating(&configurationFailures)
        status = .unavailable
      }
    }
    condition.broadcast()
    let accepted = status == .active || status == .disabled
    condition.unlock()
    return accepted
  }

  /// Records one exact completed correlation. Callers must deliberately ignore
  /// the return value when driving recovery so evidence I/O cannot become a
  /// readiness or lifecycle dependency.
  @discardableResult
  public func recordCompleted(
    correlation: HostRecoveryTransitionCorrelation,
    acceptedAt: Date,
    completedAt: Date,
    acceptedMonotonicNanoseconds: UInt64,
    completedMonotonicNanoseconds: UInt64
  ) -> Bool {
    condition.lock()
    while status == .active && recordInFlight {
      condition.wait()
    }
    guard status == .active, let writer else {
      condition.unlock()
      return false
    }
    recordInFlight = true
    condition.unlock()

    let succeeded: Bool
    do {
      try writer.recordCompleted(
        correlation: correlation,
        acceptedAt: acceptedAt,
        completedAt: completedAt,
        acceptedMonotonicNanoseconds: acceptedMonotonicNanoseconds,
        completedMonotonicNanoseconds: completedMonotonicNanoseconds
      )
      succeeded = true
    } catch {
      succeeded = false
    }

    condition.lock()
    recordInFlight = false
    if succeeded {
      incrementSaturating(&completedRecords)
    } else if status == .active {
      incrementSaturating(&recordFailures)
      self.writer = nil
      status = .unavailable
    }
    condition.broadcast()
    condition.unlock()
    return succeeded
  }

  /// Captures the exact matching wake-recovery acceptance edge. This is an
  /// evidence-only observation: rejection, disabled evidence, or clock
  /// failure cannot affect the recovery state machine.
  @discardableResult
  public func acceptSleepWake(recoveryEpoch: UInt64) -> Bool {
    guard recoveryEpoch > 0 else { return false }

    condition.lock()
    guard status == .active,
          pendingSleepWakeAcceptance == nil,
          !sleepWakeAcceptanceInFlight
    else {
      condition.unlock()
      return false
    }
    sleepWakeAcceptanceInFlight = true
    condition.unlock()

    let acceptedAt = wallClock()
    let acceptedMonotonicNanoseconds = monotonicNanoseconds()
    let clockIsValid = acceptedAt.timeIntervalSinceReferenceDate.isFinite
      && acceptedMonotonicNanoseconds > 0

    condition.lock()
    sleepWakeAcceptanceInFlight = false
    guard clockIsValid,
          status == .active,
          pendingSleepWakeAcceptance == nil
    else {
      condition.broadcast()
      condition.unlock()
      return false
    }
    pendingSleepWakeAcceptance = SleepWakeAcceptance(
      recoveryEpoch: recoveryEpoch,
      acceptedAt: acceptedAt,
      acceptedMonotonicNanoseconds: acceptedMonotonicNanoseconds
    )
    condition.broadcast()
    condition.unlock()
    return true
  }

  /// Persists only the exact accepted epoch after the core recovery owner has
  /// committed `running` and the product has published registration `ready`.
  @discardableResult
  public func recordSleepWakeCompleted(recoveryEpoch: UInt64) -> Bool {
    condition.lock()
    guard status == .active,
          let acceptance = pendingSleepWakeAcceptance,
          acceptance.recoveryEpoch == recoveryEpoch
    else {
      condition.unlock()
      return false
    }
    pendingSleepWakeAcceptance = nil
    condition.unlock()

    let completedAt = wallClock()
    let completedMonotonicNanoseconds = monotonicNanoseconds()
    return recordCompleted(
      correlation: .sleepWake(recoveryEpoch: recoveryEpoch),
      acceptedAt: acceptance.acceptedAt,
      completedAt: completedAt,
      acceptedMonotonicNanoseconds:
        acceptance.acceptedMonotonicNanoseconds,
      completedMonotonicNanoseconds: completedMonotonicNanoseconds
    )
  }

  /// Captures one exact HostCore-accepted network restart after its baseline
  /// recovery epoch and path generation have been pinned by the poll owner.
  @discardableResult
  public func acceptNetworkPath(
    pathGeneration: UInt64,
    recoveryEpoch: UInt64
  ) -> Bool {
    guard pathGeneration > 0 else { return false }

    condition.lock()
    guard status == .active,
          pendingNetworkPathAcceptance == nil,
          !networkPathAcceptanceInFlight
    else {
      condition.unlock()
      return false
    }
    networkPathAcceptanceInFlight = true
    condition.unlock()

    let acceptedAt = wallClock()
    let acceptedMonotonicNanoseconds = monotonicNanoseconds()
    let clockIsValid = acceptedAt.timeIntervalSinceReferenceDate.isFinite
      && acceptedMonotonicNanoseconds > 0

    condition.lock()
    networkPathAcceptanceInFlight = false
    guard clockIsValid,
          status == .active,
          pendingNetworkPathAcceptance == nil
    else {
      condition.broadcast()
      condition.unlock()
      return false
    }
    pendingNetworkPathAcceptance = NetworkPathAcceptance(
      pathGeneration: pathGeneration,
      recoveryEpoch: recoveryEpoch,
      acceptedAt: acceptedAt,
      acceptedMonotonicNanoseconds: acceptedMonotonicNanoseconds
    )
    condition.broadcast()
    condition.unlock()
    return true
  }

  /// Persists only the exact generation/epoch pair after direct HostCore
  /// snapshot convergence committed `running + ready`.
  @discardableResult
  public func recordNetworkPathCompleted(
    pathGeneration: UInt64,
    recoveryEpoch: UInt64
  ) -> Bool {
    condition.lock()
    guard status == .active,
          let acceptance = pendingNetworkPathAcceptance,
          acceptance.pathGeneration == pathGeneration,
          acceptance.recoveryEpoch == recoveryEpoch
    else {
      condition.unlock()
      return false
    }
    pendingNetworkPathAcceptance = nil
    condition.unlock()

    let completedAt = wallClock()
    let completedMonotonicNanoseconds = monotonicNanoseconds()
    return recordCompleted(
      correlation: .networkPath(
        pathGeneration: pathGeneration,
        recoveryEpoch: recoveryEpoch
      ),
      acceptedAt: acceptance.acceptedAt,
      completedAt: completedAt,
      acceptedMonotonicNanoseconds:
        acceptance.acceptedMonotonicNanoseconds,
      completedMonotonicNanoseconds: completedMonotonicNanoseconds
    )
  }

  /// Terminally closes admission, waits for any accepted configuration/write,
  /// then releases the retained evidence file handle.
  public func cancelAndWait() {
    condition.lock()
    switch status {
    case .cancelled:
      condition.unlock()
      return
    case .cancelling:
      while status == .cancelling {
        condition.wait()
      }
      condition.unlock()
      return
    case .idle, .configuring, .disabled, .active, .unavailable:
      status = .cancelling
      condition.broadcast()
      while configurationInFlight || sleepWakeAcceptanceInFlight
        || networkPathAcceptanceInFlight || recordInFlight
      {
        condition.wait()
      }
      pendingSleepWakeAcceptance = nil
      pendingNetworkPathAcceptance = nil
      writer = nil
      status = .cancelled
      condition.broadcast()
      condition.unlock()
    }
  }

  package static func scopeDigest(for hostInstanceID: String) -> String? {
    digest(domain: scopeDigestDomain, identity: hostInstanceID)
  }

  package static func buildDigest(for buildIdentity: String) -> String? {
    digest(domain: buildDigestDomain, identity: buildIdentity)
  }

  private static func digest(
    domain: String,
    identity: String
  ) -> String? {
    guard isBoundedIdentity(identity) else { return nil }
    var hasher = SHA256()
    hasher.update(data: Data(domain.utf8))
    hasher.update(data: Data([0]))
    hasher.update(data: Data(identity.utf8))
    let hexadecimal = Array("0123456789abcdef".utf8)
    var result = String()
    result.reserveCapacity(64)
    for byte in hasher.finalize() {
      result.append(Character(UnicodeScalar(hexadecimal[Int(byte >> 4)])))
      result.append(Character(UnicodeScalar(hexadecimal[Int(byte & 0x0F)])))
    }
    return result
  }

  private static func isBoundedIdentity(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty
      && bytes.count <= maximumIdentityUTF8Bytes
      && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
  }

  private func incrementSaturating(_ value: inout UInt64) {
    if value < UInt64.max { value += 1 }
  }
}
