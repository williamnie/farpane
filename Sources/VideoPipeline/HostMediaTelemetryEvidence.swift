import Foundation

public enum HostMediaTelemetryEvidenceError: Error, Equatable {
  case outputPathMustBeAbsolute
  case outputMustBeJSON
  case outputAlreadyExists
}

/// Explicit, one-route diagnostic export. The schema intentionally contains
/// only an allowlist of aggregate media/process metrics: no display index,
/// PID, peer/connection identity, server, credential, payload, or file path.
struct HostMediaTelemetryEvidence: Codable, Equatable {
  static let schemaName = "farpane-media-telemetry"
  static let currentSchemaVersion = 7

  let schema: String
  let schemaVersion: Int
  let evidenceKind: String
  let capturedAt: Date
  let media: Media
  let capture: Capture
  let cadence: Cadence
  let encode: Encode
  let send: Send
  let writer: Writer
  let network: Network
  let transport: Transport
  let drops: Drops
  let process: Process
  let runtimeSeconds: Double

  struct Media: Codable, Equatable {
    let codec: String
    let requestedWidth: Int
    let requestedHeight: Int
    let requestedFramesPerSecond: Int
    let captureWidth: Int?
    let captureHeight: Int?
    let pixelFormat: String?
    let hardwareAccelerated: Bool?
    let softwareFallback: Bool?
    let encoderIdentifier: String?
  }

  struct Capture: Codable, Equatable {
    let callbacks: Int
    let validFrames: Int
    let actualFramesPerSecond: Double
    let latestDirtyAreaRatio: Double?
    let averageDirtyAreaRatio: Double?
    let maximumLogicalRawFrameCopyCount: Int
    let rawFrameQueueDepth: Int
    let maximumRawFrameQueueDepth: Int
  }

  struct Cadence: Codable, Equatable {
    let contentState: String
    let targetFramesPerSecond: Int
    let appliedFramesPerSecond: Int
    let dirtyMetadataTrusted: Bool
    let pressureLevel: String
    let contentTransitions: Int
    let pressureTransitions: Int
    let configurationUpdateAttempts: Int
    let configurationUpdatesApplied: Int
    let configurationUpdateFailures: Int
    let configurationUpdateCancellations: Int
    let configurationUpdateInFlight: Bool
  }

  struct Encode: Codable, Equatable {
    let submissions: Int
    let rejected: Int
    let packets: Int
    let inFlight: Int
    let maximumInFlight: Int
    let trackedLatencies: Int
    let latencyTrackingEvictions: Int
    let latencyP50Milliseconds: Double?
    let latencyP95Milliseconds: Double?
    let latencyP99Milliseconds: Double?
    let latestLatencyMilliseconds: Double?
    let encodedBytes: UInt64
    let encodedBitRateBitsPerSecond: Double
    let keyframes: Int
  }

  struct Send: Codable, Equatable {
    let submissions: Int
    let accepted: Int
    let dropped: Int
    let recentOutcomeCount: Int
    let recentDropRate: Double
    let consecutiveDrops: Int
    let encodedQueueSamples: Int
    let encodedQueueDepth: Int?
    let maximumEncodedQueueDepth: Int?
    let encodedQueueCapacity: Int?
    let encodedQueueFinalized: Bool
  }

  struct Writer: Codable, Equatable {
    let metricSamples: Int
    let cycles: UInt64
    let subscriberDispatches: UInt64
    let dispatchWallTotalMicroseconds: UInt64
    let maximumDispatchWallMicroseconds: UInt64
    let confirmationWaitTotalMicroseconds: UInt64
    let maximumConfirmationWaitMicroseconds: UInt64
    let completedConfirmations: UInt64
    let timedOutConfirmations: UInt64
    let finalized: Bool
  }

  struct Network: Codable, Equatable {
    let metricSamples: Int
    let subscriberCount: Int
    let qosSubscriberCount: Int
    let delaySampledSubscribers: Int
    let rttSampledSubscribers: Int
    let responseDelayedSubscribers: Int
    let latestNetworkDelayMilliseconds: Int?
    let maximumNetworkDelayMilliseconds: Int?
    let latestRoundTripTimeMilliseconds: Int?
    let maximumRoundTripTimeMilliseconds: Int?
    let finalized: Bool
  }

  struct Transport: Codable, Equatable {
    let metricSamples: Int
    let subscriberCount: Int
    let directSubscribers: Int
    let relaySubscribers: Int
    let unknownSubscribers: Int
    let finalized: Bool
  }

  struct DropMetric: Codable, Equatable {
    let instrumented: Bool
    let count: Int?

    init(_ count: Int?) {
      instrumented = count != nil
      self.count = count
    }
  }

  struct Drops: Codable, Equatable {
    let captureSuperseded: DropMetric
    let encoderBackpressure: DropMetric
    let networkBackpressure: DropMetric
    let reconfigure: DropMetric
    let invalidFrame: DropMetric
    let shutdown: DropMetric
    let classified: Int
    let unclassified: Int
    let total: Int
  }

  struct Process: Codable, Equatable {
    let samples: Int
    let latestCPUPercent: Double?
    let peakCPUPercent: Double
    let latestResidentBytes: UInt64?
    let peakResidentBytes: UInt64
    let latestPhysicalFootprintBytes: UInt64?
    let peakPhysicalFootprintBytes: UInt64
    let latestThreadCount: Int?
    let peakThreadCount: Int
    let thermalState: String?
    let powerSource: String?
    let lowPowerModeEnabled: Bool?
  }

  init(snapshot: HostMediaTelemetrySnapshot, capturedAt: Date = Date()) {
    schema = Self.schemaName
    schemaVersion = Self.currentSchemaVersion
    evidenceKind = "route-stop-diagnostic-snapshot"
    self.capturedAt = capturedAt
    media = Media(
      codec: snapshot.codec.rawValue,
      requestedWidth: snapshot.requestedWidth,
      requestedHeight: snapshot.requestedHeight,
      requestedFramesPerSecond: snapshot.requestedFPS,
      captureWidth: snapshot.captureWidth,
      captureHeight: snapshot.captureHeight,
      pixelFormat: snapshot.pixelFormat,
      hardwareAccelerated: snapshot.hardwareAccelerated,
      softwareFallback: snapshot.softwareFallback,
      encoderIdentifier: snapshot.encoderID
    )
    capture = Capture(
      callbacks: snapshot.captureCallbacks,
      validFrames: snapshot.validFrames,
      actualFramesPerSecond: snapshot.actualFPS,
      latestDirtyAreaRatio: snapshot.latestDirtyAreaRatio,
      averageDirtyAreaRatio: snapshot.averageDirtyAreaRatio,
      maximumLogicalRawFrameCopyCount: snapshot.maximumLogicalRawFrameCopyCount,
      rawFrameQueueDepth: snapshot.rawFrameQueueDepth,
      maximumRawFrameQueueDepth: snapshot.maximumRawFrameQueueDepth
    )
    cadence = Cadence(
      contentState: snapshot.captureContentState.rawValue,
      targetFramesPerSecond: snapshot.captureTargetFPS,
      appliedFramesPerSecond: snapshot.captureAppliedFPS,
      dirtyMetadataTrusted: snapshot.captureDirtyMetadataTrusted,
      pressureLevel: snapshot.capturePressureLevel.rawValue,
      contentTransitions: snapshot.captureCadenceTransitions,
      pressureTransitions: snapshot.capturePressureTransitions,
      configurationUpdateAttempts: snapshot.captureConfigurationUpdateAttempts,
      configurationUpdatesApplied: snapshot.captureConfigurationUpdatesApplied,
      configurationUpdateFailures: snapshot.captureConfigurationUpdateFailures,
      configurationUpdateCancellations: snapshot.captureConfigurationUpdateCancellations,
      configurationUpdateInFlight: snapshot.captureConfigurationUpdateInFlight
    )
    encode = Encode(
      submissions: snapshot.encodeSubmissions,
      rejected: snapshot.encodeRejected,
      packets: snapshot.encodedPackets,
      inFlight: snapshot.encodeInFlight,
      maximumInFlight: snapshot.maximumEncodeInFlight,
      trackedLatencies: snapshot.trackedEncodeLatencies,
      latencyTrackingEvictions: snapshot.encodeLatencyTrackingEvictions,
      latencyP50Milliseconds: snapshot.encodeLatencyP50MS,
      latencyP95Milliseconds: snapshot.encodeLatencyP95MS,
      latencyP99Milliseconds: snapshot.encodeLatencyP99MS,
      latestLatencyMilliseconds: snapshot.latestEncodeLatencyMS,
      encodedBytes: snapshot.encodedBytes,
      encodedBitRateBitsPerSecond: snapshot.encodedBitRateBPS,
      keyframes: snapshot.keyframes
    )
    send = Send(
      submissions: snapshot.sendSubmissions,
      accepted: snapshot.sendAccepted,
      dropped: snapshot.sendDropped,
      recentOutcomeCount: snapshot.recentSendOutcomeCount,
      recentDropRate: snapshot.recentSendDropRate,
      consecutiveDrops: snapshot.consecutiveSendDrops,
      encodedQueueSamples: snapshot.encodedQueueSamples,
      encodedQueueDepth: snapshot.encodedQueueDepth,
      maximumEncodedQueueDepth: snapshot.maximumEncodedQueueDepth,
      encodedQueueCapacity: snapshot.encodedQueueCapacity,
      encodedQueueFinalized: snapshot.encodedQueueFinalized
    )
    writer = Writer(
      metricSamples: snapshot.writerMetricSamples,
      cycles: snapshot.writerCycles,
      subscriberDispatches: snapshot.subscriberDispatches,
      dispatchWallTotalMicroseconds: snapshot.dispatchWallTotalUS,
      maximumDispatchWallMicroseconds: snapshot.maximumDispatchWallUS,
      confirmationWaitTotalMicroseconds: snapshot.confirmationWaitTotalUS,
      maximumConfirmationWaitMicroseconds: snapshot.maximumConfirmationWaitUS,
      completedConfirmations: snapshot.completedConfirmations,
      timedOutConfirmations: snapshot.timedOutConfirmations,
      finalized: snapshot.writerTimingFinalized
    )
    network = Network(
      metricSamples: snapshot.networkMetricSamples,
      subscriberCount: snapshot.networkSubscriberCount,
      qosSubscriberCount: snapshot.qosSubscriberCount,
      delaySampledSubscribers: snapshot.delaySampledSubscribers,
      rttSampledSubscribers: snapshot.rttSampledSubscribers,
      responseDelayedSubscribers: snapshot.responseDelayedSubscribers,
      latestNetworkDelayMilliseconds: snapshot.networkDelayMS,
      maximumNetworkDelayMilliseconds: snapshot.maximumNetworkDelayMS,
      latestRoundTripTimeMilliseconds: snapshot.roundTripTimeMS,
      maximumRoundTripTimeMilliseconds: snapshot.maximumRoundTripTimeMS,
      finalized: snapshot.networkMetricsFinalized
    )
    transport = Transport(
      metricSamples: snapshot.transportMetricSamples,
      subscriberCount: snapshot.transportSubscriberCount,
      directSubscribers: snapshot.directSubscribers,
      relaySubscribers: snapshot.relaySubscribers,
      unknownSubscribers: snapshot.unknownSubscribers,
      finalized: snapshot.transportMetricsFinalized
    )
    drops = Drops(
      captureSuperseded: DropMetric(snapshot.drops.captureSuperseded),
      encoderBackpressure: DropMetric(snapshot.drops.encoderBackpressure),
      networkBackpressure: DropMetric(snapshot.drops.networkBackpressure),
      reconfigure: DropMetric(snapshot.drops.reconfigure),
      invalidFrame: DropMetric(snapshot.drops.invalidFrame),
      shutdown: DropMetric(snapshot.drops.shutdown),
      classified: snapshot.drops.classified,
      unclassified: snapshot.drops.unclassified,
      total: snapshot.drops.total
    )
    process = Process(
      samples: snapshot.processSamples,
      latestCPUPercent: snapshot.processCPUPercent,
      peakCPUPercent: snapshot.peakProcessCPUPercent,
      latestResidentBytes: snapshot.residentBytes,
      peakResidentBytes: snapshot.peakResidentBytes,
      latestPhysicalFootprintBytes: snapshot.physicalFootprintBytes,
      peakPhysicalFootprintBytes: snapshot.peakPhysicalFootprintBytes,
      latestThreadCount: snapshot.threadCount,
      peakThreadCount: snapshot.peakThreadCount,
      thermalState: snapshot.thermalState,
      powerSource: snapshot.powerSource,
      lowPowerModeEnabled: snapshot.lowPowerModeEnabled
    )
    runtimeSeconds = snapshot.runtimeSeconds
  }
}

public struct HostMediaTelemetryEvidenceWriter: Sendable {
  public static let outputEnvironmentKey = "FARPANE_HOST_TELEMETRY_OUTPUT"

  private let outputURL: URL

  public init(outputURL: URL, fileManager: FileManager = .default) throws {
    guard outputURL.path.hasPrefix("/") else {
      throw HostMediaTelemetryEvidenceError.outputPathMustBeAbsolute
    }
    guard outputURL.pathExtension.lowercased() == "json" else {
      throw HostMediaTelemetryEvidenceError.outputMustBeJSON
    }
    guard !fileManager.fileExists(atPath: outputURL.path) else {
      throw HostMediaTelemetryEvidenceError.outputAlreadyExists
    }
    self.outputURL = outputURL.standardizedFileURL
  }

  public static func configured(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) throws -> HostMediaTelemetryEvidenceWriter? {
    guard let path = environment[outputEnvironmentKey] else { return nil }
    guard !path.isEmpty, NSString(string: path).isAbsolutePath else {
      throw HostMediaTelemetryEvidenceError.outputPathMustBeAbsolute
    }
    return try HostMediaTelemetryEvidenceWriter(
      outputURL: URL(fileURLWithPath: path, isDirectory: false),
      fileManager: fileManager
    )
  }

  public func write(
    snapshot: HostMediaTelemetrySnapshot,
    capturedAt: Date = Date(),
    fileManager: FileManager = .default
  ) throws {
    guard !fileManager.fileExists(atPath: outputURL.path) else {
      throw HostMediaTelemetryEvidenceError.outputAlreadyExists
    }
    let evidence = HostMediaTelemetryEvidence(
      snapshot: snapshot,
      capturedAt: capturedAt
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(evidence)
    try fileManager.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let temporaryURL = outputURL.deletingLastPathComponent()
      .appendingPathComponent(".farpane-telemetry-\(UUID().uuidString).tmp")
    defer { try? fileManager.removeItem(at: temporaryURL) }
    do {
      // The temp file is complete before an atomic hard-link publishes it.
      // link(2) refuses an existing destination, so concurrent writers cannot
      // replace previously captured evidence.
      try data.write(to: temporaryURL, options: .withoutOverwriting)
      try fileManager.linkItem(at: temporaryURL, to: outputURL)
    } catch let error as CocoaError where error.code == .fileWriteFileExists {
      throw HostMediaTelemetryEvidenceError.outputAlreadyExists
    }
  }
}
