import Foundation

public enum HostRecoveryTransitionEvidenceError: Error, Equatable {
  case outputPathMustBeAbsolute
  case outputMustBeJSONLines
  case outputAlreadyExists
  case incompleteConfiguration
  case invalidHostInstanceScopeDigest
  case invalidBuildIdentityDigest
  case invalidTiming
  case invalidCorrelation
  case recordCapacityExceeded
}

public enum HostRecoveryTransitionCorrelation: Equatable, Sendable {
  case sleepWake(recoveryEpoch: UInt64)
  case networkPath(pathGeneration: UInt64, recoveryEpoch: UInt64)
  case displayReconfigure(
    previousDisplayRevision: UInt64,
    replacementDisplayRevision: UInt64,
    previousConnectionEpoch: UInt64,
    replacementConnectionEpoch: UInt64,
    previousCodecEpoch: UInt64,
    replacementCodecEpoch: UInt64
  )
}

/// Writes sanitized proofs for successfully converged Host recovery transitions.
///
/// The caller supplies SHA-256 digests, never raw Host/build identity. Failed or
/// partial recovery attempts cannot be recorded as completed evidence because
/// every correlation is validated before one JSONL record is appended.
public final class HostRecoveryTransitionEvidenceWriter: @unchecked Sendable {
  public static let outputEnvironmentKey = "FARPANE_HOST_RECOVERY_OUTPUT"
  public static let hostInstanceScopeDigestEnvironmentKey =
    "FARPANE_HOST_RECOVERY_SCOPE_SHA256"
  public static let buildIdentityDigestEnvironmentKey =
    "FARPANE_HOST_RECOVERY_BUILD_SHA256"
  public static let maximumRecordCount: UInt64 = 128

  private enum Kind: String, Codable {
    case sleepWake
    case networkPath
    case displayReconfigure
  }

  private enum Status: String, Codable {
    case completed
  }

  private enum EncodedCorrelation: Encodable {
    struct SleepWake: Encodable {
      let recoveryEpoch: UInt64
      let runningReadyConverged = true
    }

    struct NetworkPath: Encodable {
      let pathGeneration: UInt64
      let recoveryEpoch: UInt64
      let runningReadyConverged = true
    }

    struct DisplayReconfigure: Encodable {
      let previousDisplayRevision: UInt64
      let replacementDisplayRevision: UInt64
      let previousConnectionEpoch: UInt64
      let replacementConnectionEpoch: UInt64
      let previousCodecEpoch: UInt64
      let replacementCodecEpoch: UInt64
      let freshRouteConverged = true
    }

    case sleepWake(SleepWake)
    case networkPath(NetworkPath)
    case displayReconfigure(DisplayReconfigure)

    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      switch self {
      case .sleepWake(let value):
        try container.encode(value)
      case .networkPath(let value):
        try container.encode(value)
      case .displayReconfigure(let value):
        try container.encode(value)
      }
    }
  }

  private struct Record: Encodable {
    let schema: String
    let schemaVersion: Int
    let sequence: UInt64
    let kind: Kind
    let acceptedAt: Date
    let completedAt: Date
    let acceptedMonotonicNanoseconds: UInt64
    let completedMonotonicNanoseconds: UInt64
    let status: Status
    let hostInstanceScopeSHA256: String
    let buildIdentitySHA256: String
    let correlation: EncodedCorrelation
  }

  private let outputHandle: FileHandle
  private let hostInstanceScopeSHA256: String
  private let buildIdentitySHA256: String
  private let lock = NSLock()
  private var sequence: UInt64 = 0

  public init(
    outputURL: URL,
    hostInstanceScopeSHA256: String,
    buildIdentitySHA256: String,
    fileManager: FileManager = .default
  ) throws {
    guard outputURL.isFileURL,
          NSString(string: outputURL.path).isAbsolutePath
    else {
      throw HostRecoveryTransitionEvidenceError.outputPathMustBeAbsolute
    }
    guard outputURL.pathExtension.lowercased() == "jsonl" else {
      throw HostRecoveryTransitionEvidenceError.outputMustBeJSONLines
    }
    guard Self.isLowercaseSHA256(hostInstanceScopeSHA256) else {
      throw HostRecoveryTransitionEvidenceError.invalidHostInstanceScopeDigest
    }
    guard Self.isLowercaseSHA256(buildIdentitySHA256) else {
      throw HostRecoveryTransitionEvidenceError.invalidBuildIdentityDigest
    }
    guard !fileManager.fileExists(atPath: outputURL.path) else {
      throw HostRecoveryTransitionEvidenceError.outputAlreadyExists
    }
    let standardizedURL = outputURL.standardizedFileURL
    try fileManager.createDirectory(
      at: standardizedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try Data().write(to: standardizedURL, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      throw HostRecoveryTransitionEvidenceError.outputAlreadyExists
    }
    outputHandle = try FileHandle(forWritingTo: standardizedURL)
    self.hostInstanceScopeSHA256 = hostInstanceScopeSHA256
    self.buildIdentitySHA256 = buildIdentitySHA256
  }

  deinit {
    try? outputHandle.close()
  }

  public static func configured(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws -> HostRecoveryTransitionEvidenceWriter? {
    let output = environment[outputEnvironmentKey]
    let scope = environment[hostInstanceScopeDigestEnvironmentKey]
    let build = environment[buildIdentityDigestEnvironmentKey]
    guard output != nil || scope != nil || build != nil else { return nil }
    guard let output, !output.isEmpty,
          let scope, !scope.isEmpty,
          let build, !build.isEmpty
    else {
      throw HostRecoveryTransitionEvidenceError.incompleteConfiguration
    }
    guard NSString(string: output).isAbsolutePath else {
      throw HostRecoveryTransitionEvidenceError.outputPathMustBeAbsolute
    }
    return try HostRecoveryTransitionEvidenceWriter(
      outputURL: URL(fileURLWithPath: output, isDirectory: false),
      hostInstanceScopeSHA256: scope,
      buildIdentitySHA256: build,
      fileManager: fileManager
    )
  }

  /// Appends one successfully converged transition and returns its sequence.
  /// Wall time provides human correlation; monotonic time is authoritative for
  /// accepted-before-completed ordering.
  @discardableResult
  public func recordCompleted(
    correlation: HostRecoveryTransitionCorrelation,
    acceptedAt: Date,
    completedAt: Date,
    acceptedMonotonicNanoseconds: UInt64,
    completedMonotonicNanoseconds: UInt64
  ) throws -> UInt64 {
    guard completedAt >= acceptedAt,
          acceptedMonotonicNanoseconds > 0,
          completedMonotonicNanoseconds > acceptedMonotonicNanoseconds
    else {
      throw HostRecoveryTransitionEvidenceError.invalidTiming
    }
    let (kind, encodedCorrelation) = try Self.validate(correlation)
    return try lock.withLock {
      guard sequence < Self.maximumRecordCount else {
        throw HostRecoveryTransitionEvidenceError.recordCapacityExceeded
      }
      let nextSequence = sequence + 1
      let record = Record(
        schema: "farpane-host-recovery-transition",
        schemaVersion: 1,
        sequence: nextSequence,
        kind: kind,
        acceptedAt: acceptedAt,
        completedAt: completedAt,
        acceptedMonotonicNanoseconds: acceptedMonotonicNanoseconds,
        completedMonotonicNanoseconds: completedMonotonicNanoseconds,
        status: .completed,
        hostInstanceScopeSHA256: hostInstanceScopeSHA256,
        buildIdentitySHA256: buildIdentitySHA256,
        correlation: encodedCorrelation
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var line = try encoder.encode(record)
      line.append(0x0A)
      try outputHandle.seekToEnd()
      try outputHandle.write(contentsOf: line)
      sequence = nextSequence
      return nextSequence
    }
  }

  private static func validate(
    _ correlation: HostRecoveryTransitionCorrelation
  ) throws -> (Kind, EncodedCorrelation) {
    switch correlation {
    case .sleepWake(let recoveryEpoch):
      guard recoveryEpoch > 0 else {
        throw HostRecoveryTransitionEvidenceError.invalidCorrelation
      }
      return (
        .sleepWake,
        .sleepWake(.init(recoveryEpoch: recoveryEpoch))
      )
    case .networkPath(let pathGeneration, let recoveryEpoch):
      guard pathGeneration > 0, recoveryEpoch > 0 else {
        throw HostRecoveryTransitionEvidenceError.invalidCorrelation
      }
      return (
        .networkPath,
        .networkPath(.init(
          pathGeneration: pathGeneration,
          recoveryEpoch: recoveryEpoch
        ))
      )
    case .displayReconfigure(
      let previousDisplayRevision,
      let replacementDisplayRevision,
      let previousConnectionEpoch,
      let replacementConnectionEpoch,
      let previousCodecEpoch,
      let replacementCodecEpoch
    ):
      guard previousDisplayRevision > 0,
            replacementDisplayRevision > 0,
            previousConnectionEpoch > 0,
            replacementConnectionEpoch > previousConnectionEpoch,
            previousCodecEpoch > 0,
            replacementCodecEpoch > previousCodecEpoch
      else {
        throw HostRecoveryTransitionEvidenceError.invalidCorrelation
      }
      return (
        .displayReconfigure,
        .displayReconfigure(.init(
          previousDisplayRevision: previousDisplayRevision,
          replacementDisplayRevision: replacementDisplayRevision,
          previousConnectionEpoch: previousConnectionEpoch,
          replacementConnectionEpoch: replacementConnectionEpoch,
          previousCodecEpoch: previousCodecEpoch,
          replacementCodecEpoch: replacementCodecEpoch
        ))
      )
    }
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
