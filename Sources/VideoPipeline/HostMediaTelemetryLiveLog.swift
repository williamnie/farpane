import Foundation

public enum HostMediaLiveLogError: Error, Equatable {
  case outputPathMustBeAbsolute
  case outputMustBeJSONLines
  case outputAlreadyExists
  case invalidMaximumPeriodicRecords
  case invalidRetentionPolicy
  case retentionFailed
}

public enum HostMediaLiveLogEvent: String, Sendable {
  case routeStarted
  case periodic
  case captureSuspended
  case routeStopped
  case routeStartFailed
}

package protocol HostMediaLiveLogRecording: Sendable {
  @discardableResult
  func record(
    snapshot: HostMediaTelemetrySnapshot,
    event: HostMediaLiveLogEvent,
    capturedAt: Date,
    monotonicNanoseconds: UInt64
  ) throws -> Bool
}

/// Sanitized, per-route performance history written by the Host app.
///
/// The allowlist intentionally excludes local/peer IDs, server configuration,
/// credentials, display identifiers, frame contents and encoded payloads.
public final class HostMediaTelemetryLiveLogWriter: @unchecked Sendable {
  public static let minimumPeriodicIntervalNanoseconds: UInt64 = 1_000_000_000
  public static let maximumRetainedLogFiles = 24
  public static let maximumRetentionAge: TimeInterval = 7 * 24 * 60 * 60

  private static let productLogPrefix = "host-media-live-"
  private static let productLogSuffix = ".jsonl"

  private struct RetentionCandidate {
    let url: URL
    let modifiedAt: Date
  }

  private struct FrameStatusCounts: Codable {
    let complete: Int
    let idle: Int
    let blank: Int
    let suspended: Int
    let started: Int
    let stopped: Int
    let missingOrInvalid: Int
    let unknown: Int

    init(_ counts: HostCaptureFrameStatusCounts) {
      complete = counts.complete
      idle = counts.idle
      blank = counts.blank
      suspended = counts.suspended
      started = counts.started
      stopped = counts.stopped
      missingOrInvalid = counts.missingOrInvalid
      unknown = counts.unknown
    }
  }

  private struct DirtyRectsAttachmentCounts: Codable {
    let absent: Int
    let unrecognized: Int
    let recognizedEmpty: Int
    let recognizedNonEmpty: Int

    init(_ counts: HostCaptureDirtyRectsAttachmentCounts) {
      absent = counts.absent
      unrecognized = counts.unrecognized
      recognizedEmpty = counts.recognizedEmpty
      recognizedNonEmpty = counts.recognizedNonEmpty
    }
  }

  private struct Record: Codable {
    let schema: String
    let schemaVersion: Int
    let sequence: UInt64
    let capturedAt: Date
    let monotonicNanoseconds: UInt64
    let event: String
    let recentWindowSeconds: Int
    let codec: String
    let requestedFPS: Int
    let recentCaptureFPS: Double
    let recentEncodedFPS: Double
    let recentRustAdmissionFPS: Double
    let captureAverageFPS: Double
    let captureTargetFPS: Int
    let captureAppliedFPS: Int
    let captureContentState: String
    let captureDirtyMetadataTrusted: Bool
    let captureCallbackCount: Int
    let captureFrameStatusCounts: FrameStatusCounts
    let captureCompleteDirtyRectsCounts: DirtyRectsAttachmentCounts
    let latestDirtyAreaRatio: Double?
    let captureAppliedPressureLevel: String
    let captureObservedPressureLevel: String
    let capturePressureCauses: [String]
    let captureConfigurationUpdateInFlight: Bool
    let encodeInFlight: Int
    let latestEncodeLatencyMS: Double?
    let recentSendOutcomeCount: Int
    let recentSendDropRate: Double
    let consecutiveSendDrops: Int
    let encodedQueueDepth: Int?
    let encodedQueueCapacity: Int?
    let networkDelayMS: Int?
    let roundTripTimeMS: Int?
    let responseDelayedSubscribers: Int
    let processCPUPercent: Double?
    let residentBytes: UInt64?
    let physicalFootprintBytes: UInt64?
    let thermalState: String?
    let powerSource: String?
    let lowPowerModeEnabled: Bool?
    let runtimeSeconds: Double

    init(
      snapshot: HostMediaTelemetrySnapshot,
      sequence: UInt64,
      event: HostMediaLiveLogEvent,
      capturedAt: Date,
      monotonicNanoseconds: UInt64
    ) {
      schema = "farpane-host-media-live"
      schemaVersion = 3
      self.sequence = sequence
      self.capturedAt = capturedAt
      self.monotonicNanoseconds = monotonicNanoseconds
      self.event = event.rawValue
      recentWindowSeconds = 5
      codec = snapshot.codec.rawValue
      requestedFPS = snapshot.requestedFPS
      recentCaptureFPS = snapshot.recentCaptureFPS
      recentEncodedFPS = snapshot.recentEncodedFPS
      recentRustAdmissionFPS = snapshot.recentSendAcceptedFPS
      captureAverageFPS = snapshot.actualFPS
      captureTargetFPS = snapshot.captureTargetFPS
      captureAppliedFPS = snapshot.captureAppliedFPS
      captureContentState = snapshot.captureContentState.rawValue
      captureDirtyMetadataTrusted = snapshot.captureDirtyMetadataTrusted
      captureCallbackCount = snapshot.captureCallbacks
      captureFrameStatusCounts = FrameStatusCounts(snapshot.captureFrameStatusCounts)
      captureCompleteDirtyRectsCounts = DirtyRectsAttachmentCounts(
        snapshot.captureCompleteDirtyRectsCounts
      )
      latestDirtyAreaRatio = snapshot.latestDirtyAreaRatio
      captureAppliedPressureLevel = snapshot.capturePressureLevel.rawValue
      captureObservedPressureLevel = snapshot.captureObservedPressureLevel.rawValue
      capturePressureCauses = snapshot.capturePressureCauses.map(\.rawValue)
      captureConfigurationUpdateInFlight = snapshot.captureConfigurationUpdateInFlight
      encodeInFlight = snapshot.encodeInFlight
      latestEncodeLatencyMS = snapshot.latestEncodeLatencyMS
      recentSendOutcomeCount = snapshot.recentSendOutcomeCount
      recentSendDropRate = snapshot.recentSendDropRate
      consecutiveSendDrops = snapshot.consecutiveSendDrops
      encodedQueueDepth = snapshot.encodedQueueDepth
      encodedQueueCapacity = snapshot.encodedQueueCapacity
      networkDelayMS = snapshot.networkDelayMS
      roundTripTimeMS = snapshot.roundTripTimeMS
      responseDelayedSubscribers = snapshot.responseDelayedSubscribers
      processCPUPercent = snapshot.processCPUPercent
      residentBytes = snapshot.residentBytes
      physicalFootprintBytes = snapshot.physicalFootprintBytes
      thermalState = snapshot.thermalState
      powerSource = snapshot.powerSource
      lowPowerModeEnabled = snapshot.lowPowerModeEnabled
      runtimeSeconds = snapshot.runtimeSeconds
    }
  }

  public let outputURL: URL

  private let maximumPeriodicRecords: Int
  private let lock = NSLock()
  private var sequence: UInt64 = 0
  private var periodicRecords = 0
  private var lastPeriodicRecordNanoseconds: UInt64?

  public init(
    outputURL: URL,
    maximumPeriodicRecords: Int = 3_600,
    fileManager: FileManager = .default
  ) throws {
    guard NSString(string: outputURL.path).isAbsolutePath else {
      throw HostMediaLiveLogError.outputPathMustBeAbsolute
    }
    guard outputURL.pathExtension.lowercased() == "jsonl" else {
      throw HostMediaLiveLogError.outputMustBeJSONLines
    }
    guard !fileManager.fileExists(atPath: outputURL.path) else {
      throw HostMediaLiveLogError.outputAlreadyExists
    }
    guard maximumPeriodicRecords > 0 else {
      throw HostMediaLiveLogError.invalidMaximumPeriodicRecords
    }
    let standardizedURL = outputURL.standardizedFileURL
    try fileManager.createDirectory(
      at: standardizedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    do {
      try Data().write(to: standardizedURL, options: .withoutOverwriting)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      throw HostMediaLiveLogError.outputAlreadyExists
    }
    self.outputURL = standardizedURL
    self.maximumPeriodicRecords = maximumPeriodicRecords
  }

  public static func makeDefault(
    capturedAt: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> HostMediaTelemetryLiveLogWriter {
    let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library",
        isDirectory: true
      )
    let directory = libraryURL
      .appendingPathComponent("Logs", isDirectory: true)
      .appendingPathComponent("FarPane", isDirectory: true)
      .appendingPathComponent("HostMedia", isDirectory: true)
    return try makeDefault(
      in: directory,
      capturedAt: capturedAt,
      maximumRetainedFiles: maximumRetainedLogFiles,
      maximumRetentionAge: maximumRetentionAge,
      fileManager: fileManager
    )
  }

  package static func makeDefault(
    in directory: URL,
    capturedAt: Date = Date(),
    maximumRetainedFiles: Int = maximumRetainedLogFiles,
    maximumRetentionAge: TimeInterval = maximumRetentionAge,
    fileManager: FileManager = .default,
    retentionRemoval: (URL) throws -> Void = unlinkRetainedLog
  ) throws -> HostMediaTelemetryLiveLogWriter {
    guard NSString(string: directory.path).isAbsolutePath else {
      throw HostMediaLiveLogError.outputPathMustBeAbsolute
    }
    guard maximumRetainedFiles > 0,
          maximumRetentionAge.isFinite,
          maximumRetentionAge > 0
    else {
      throw HostMediaLiveLogError.invalidRetentionPolicy
    }
    let standardizedDirectory = directory.standardizedFileURL
    try fileManager.createDirectory(
      at: standardizedDirectory,
      withIntermediateDirectories: true
    )
    try enforceRetention(
      in: standardizedDirectory,
      capturedAt: capturedAt,
      maximumExistingFiles: maximumRetainedFiles - 1,
      maximumRetentionAge: maximumRetentionAge,
      fileManager: fileManager,
      retentionRemoval: retentionRemoval
    )
    let timestamp = ISO8601DateFormatter().string(from: capturedAt)
      .replacingOccurrences(of: ":", with: "")
    let filename = "\(productLogPrefix)\(timestamp)-\(UUID().uuidString)\(productLogSuffix)"
    return try HostMediaTelemetryLiveLogWriter(
      outputURL: standardizedDirectory.appendingPathComponent(
        filename,
        isDirectory: false
      ),
      fileManager: fileManager
    )
  }

  private static func enforceRetention(
    in directory: URL,
    capturedAt: Date,
    maximumExistingFiles: Int,
    maximumRetentionAge: TimeInterval,
    fileManager: FileManager,
    retentionRemoval: (URL) throws -> Void
  ) throws {
    let urls: [URL]
    do {
      urls = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    } catch {
      throw HostMediaLiveLogError.retentionFailed
    }
    var candidates: [RetentionCandidate] = []
    for url in urls where isProductLogFilename(url.lastPathComponent) {
      let attributes: [FileAttributeKey: Any]
      do {
        attributes = try fileManager.attributesOfItem(atPath: url.path)
      } catch {
        throw HostMediaLiveLogError.retentionFailed
      }
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
              == UInt32(geteuid()),
            (attributes[.referenceCount] as? NSNumber)?.intValue == 1
      else { continue }
      candidates.append(RetentionCandidate(
        url: url,
        modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast
      ))
    }
    candidates.sort {
      if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt < $1.modifiedAt }
      return $0.url.lastPathComponent < $1.url.lastPathComponent
    }

    let cutoff = capturedAt.addingTimeInterval(-maximumRetentionAge)
    let stale = candidates.filter { $0.modifiedAt < cutoff }
    let recent = candidates.filter { $0.modifiedAt >= cutoff }
    let overflowCount = max(0, recent.count - maximumExistingFiles)
    let removals = stale + recent.prefix(overflowCount)
    do {
      for candidate in removals {
        try retentionRemoval(candidate.url)
      }
    } catch {
      throw HostMediaLiveLogError.retentionFailed
    }
  }

  private static func isProductLogFilename(_ filename: String) -> Bool {
    guard filename.hasPrefix(productLogPrefix),
          filename.hasSuffix(productLogSuffix)
    else { return false }
    let stem = filename
      .dropFirst(productLogPrefix.count)
      .dropLast(productLogSuffix.count)
    guard stem.count > 37 else { return false }
    let uuidStart = stem.index(stem.endIndex, offsetBy: -36)
    guard stem[stem.index(before: uuidStart)] == "-" else { return false }
    return UUID(uuidString: String(stem[uuidStart...])) != nil
  }

  /// `unlink` removes one directory entry and never recursively removes a
  /// directory if the path changes after metadata validation.
  private static func unlinkRetainedLog(_ url: URL) throws {
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return unlink(path)
    }
    guard result == 0 else { throw HostMediaLiveLogError.retentionFailed }
  }

  /// Periodic samples are bounded to one line per second. Lifecycle records
  /// are always written so short or failed routes remain diagnosable.
  @discardableResult
  public func record(
    snapshot: HostMediaTelemetrySnapshot,
    event: HostMediaLiveLogEvent = .periodic,
    capturedAt: Date = Date(),
    monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
  ) throws -> Bool {
    try lock.withLiveLogLock {
      if event == .periodic {
        guard periodicRecords < maximumPeriodicRecords else { return false }
        if let lastPeriodicRecordNanoseconds,
           monotonicNanoseconds >= lastPeriodicRecordNanoseconds,
           monotonicNanoseconds - lastPeriodicRecordNanoseconds
            < Self.minimumPeriodicIntervalNanoseconds {
          return false
        }
      }
      let nextSequence = sequence &+ 1
      let record = Record(
        snapshot: snapshot,
        sequence: nextSequence,
        event: event,
        capturedAt: capturedAt,
        monotonicNanoseconds: monotonicNanoseconds
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
      if event == .periodic {
        periodicRecords += 1
        lastPeriodicRecordNanoseconds = monotonicNanoseconds
      }
      return true
    }
  }
}

extension HostMediaTelemetryLiveLogWriter: HostMediaLiveLogRecording {}

private extension NSLock {
  func withLiveLogLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
