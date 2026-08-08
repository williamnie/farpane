import Foundation

public enum HostRuntimeStateEvidenceError: Error, Equatable {
  case outputPathMustBeAbsolute
  case outputMustBeJSONLines
  case outputAlreadyExists
  case invalidHostState
  case invalidRegistrationStatus
}

/// Sanitized app-local Host state history for idle/runtime acceptance.
///
/// This is intentionally separate from HostCore snapshot JSON: it does not
/// change the Rust ABI and never persists host/local IDs, connection IDs,
/// server configuration, credentials, media payloads, or output paths.
public final class HostRuntimeStateEvidenceWriter: @unchecked Sendable {
  public static let outputEnvironmentKey = "FARPANE_HOST_STATE_OUTPUT"
  public static let minimumPeriodicIntervalNanoseconds: UInt64 = 1_000_000_000

  private static let allowedHostStates: Set<String> = [
    "created", "starting", "ready", "stopping", "stopped", "error", "unavailable",
  ]
  private static let allowedRegistrationStatuses: Set<String> = [
    "notStarted", "pending", "ready", "degraded", "unavailable",
  ]

  private struct Record: Codable, Equatable {
    let schema: String
    let schemaVersion: Int
    let sequence: UInt64
    let capturedAt: Date
    let monotonicNanoseconds: UInt64
    let hostRuntimeActive: Bool
    let hostState: String
    let registrationStatus: String
    let hostSnapshotObservedAtUnixMilliseconds: UInt64?
    let mediaRouteActive: Bool
    let mediaPipelineActive: Bool
  }

  private let outputURL: URL
  private let lock = NSLock()
  private var sequence: UInt64 = 0
  private var lastRecordNanoseconds: UInt64?

  public init(outputURL: URL, fileManager: FileManager = .default) throws {
    guard NSString(string: outputURL.path).isAbsolutePath else {
      throw HostRuntimeStateEvidenceError.outputPathMustBeAbsolute
    }
    guard outputURL.pathExtension.lowercased() == "jsonl" else {
      throw HostRuntimeStateEvidenceError.outputMustBeJSONLines
    }
    guard !fileManager.fileExists(atPath: outputURL.path) else {
      throw HostRuntimeStateEvidenceError.outputAlreadyExists
    }
    let standardizedURL = outputURL.standardizedFileURL
    try fileManager.createDirectory(
      at: standardizedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try Data().write(to: standardizedURL, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      throw HostRuntimeStateEvidenceError.outputAlreadyExists
    }
    self.outputURL = standardizedURL
  }

  public static func configured(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws -> HostRuntimeStateEvidenceWriter? {
    guard let path = environment[outputEnvironmentKey] else { return nil }
    guard !path.isEmpty, NSString(string: path).isAbsolutePath else {
      throw HostRuntimeStateEvidenceError.outputPathMustBeAbsolute
    }
    return try HostRuntimeStateEvidenceWriter(
      outputURL: URL(fileURLWithPath: path, isDirectory: false),
      fileManager: fileManager
    )
  }

  /// Appends at most one periodic record per second. Lifecycle transitions
  /// pass `force=true` so a short route/start/stop cannot disappear between
  /// periodic samples.
  @discardableResult
  public func record(
    hostRuntimeActive: Bool,
    hostState: String,
    registrationStatus: String,
    hostSnapshotObservedAtUnixMilliseconds: UInt64?,
    mediaRouteActive: Bool,
    mediaPipelineActive: Bool,
    force: Bool = false,
    capturedAt: Date = Date(),
    monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws -> Bool {
    guard Self.allowedHostStates.contains(hostState) else {
      throw HostRuntimeStateEvidenceError.invalidHostState
    }
    guard Self.allowedRegistrationStatuses.contains(registrationStatus) else {
      throw HostRuntimeStateEvidenceError.invalidRegistrationStatus
    }
    return try lock.withLock {
      if !force, let lastRecordNanoseconds,
         monotonicNanoseconds >= lastRecordNanoseconds,
         monotonicNanoseconds - lastRecordNanoseconds
          < Self.minimumPeriodicIntervalNanoseconds {
        return false
      }
      let nextSequence = sequence &+ 1
      let record = Record(
        schema: "farpane-host-runtime-state",
        schemaVersion: 1,
        sequence: nextSequence,
        capturedAt: capturedAt,
        monotonicNanoseconds: monotonicNanoseconds,
        hostRuntimeActive: hostRuntimeActive,
        hostState: hostState,
        registrationStatus: registrationStatus,
        hostSnapshotObservedAtUnixMilliseconds: hostSnapshotObservedAtUnixMilliseconds,
        mediaRouteActive: mediaRouteActive,
        mediaPipelineActive: mediaPipelineActive
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var line = try encoder.encode(record)
      line.append(0x0A)
      let handle = try FileHandle(forWritingTo: outputURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
      sequence = nextSequence
      lastRecordNanoseconds = monotonicNanoseconds
      return true
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
