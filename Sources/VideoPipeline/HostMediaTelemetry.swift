import CoreVideo
import Foundation

public enum HostMediaDropReason: String, CaseIterable, Sendable {
  case captureSuperseded
  case encoderBackpressure
  case networkBackpressure
  case reconfigure
  case invalidFrame
  case shutdown
}

public struct HostMediaDropCounts: Equatable, Sendable {
  public let captureSuperseded: Int?
  public let encoderBackpressure: Int?
  public let networkBackpressure: Int?
  public let reconfigure: Int?
  public let invalidFrame: Int?
  public let shutdown: Int?
  public let classified: Int
  public let unclassified: Int

  public var total: Int {
    let (sum, overflow) = classified.addingReportingOverflow(unclassified)
    return overflow ? Int.max : sum
  }
}

public struct HostMediaTelemetrySnapshot: Equatable, Sendable {
  public let codec: HostPipelineCodec
  public let requestedWidth: Int
  public let requestedHeight: Int
  public let requestedFPS: Int
  public let captureWidth: Int?
  public let captureHeight: Int?
  public let pixelFormat: String?
  public let captureCallbacks: Int
  public let validFrames: Int
  public let actualFPS: Double
  public let recentCaptureFPS: Double
  public let recentEncodedFPS: Double
  public let recentSendAcceptedFPS: Double
  public let captureContentState: HostCaptureContentState
  public let captureTargetFPS: Int
  public let captureAppliedFPS: Int
  public let captureDirtyMetadataTrusted: Bool
  public let capturePressureLevel: HostCapturePressureLevel
  public let captureObservedPressureLevel: HostCapturePressureLevel
  public let capturePressureCauses: [HostCapturePressureCause]
  public let captureCadenceTransitions: Int
  public let capturePressureTransitions: Int
  public let captureConfigurationUpdateAttempts: Int
  public let captureConfigurationUpdatesApplied: Int
  public let captureConfigurationUpdateFailures: Int
  public let captureConfigurationUpdateCancellations: Int
  public let captureConfigurationUpdateInFlight: Bool
  public let latestDirtyAreaRatio: Double?
  public let averageDirtyAreaRatio: Double?
  public let maximumLogicalRawFrameCopyCount: Int
  public let rawFrameQueueDepth: Int
  public let maximumRawFrameQueueDepth: Int
  public let encodeSubmissions: Int
  public let encodeRejected: Int
  public let encodedPackets: Int
  public let encodeInFlight: Int
  public let maximumEncodeInFlight: Int
  public let trackedEncodeLatencies: Int
  public let encodeLatencyTrackingEvictions: Int
  public let encodeLatencyP50MS: Double?
  public let encodeLatencyP95MS: Double?
  public let encodeLatencyP99MS: Double?
  public let latestEncodeLatencyMS: Double?
  public let encodedBytes: UInt64
  public let encodedBitRateBPS: Double
  public let keyframes: Int
  public let sendSubmissions: Int
  public let sendAccepted: Int
  public let sendDropped: Int
  public let recentSendOutcomeCount: Int
  public let recentSendDropRate: Double
  public let consecutiveSendDrops: Int
  public let encodedQueueSamples: Int
  public let encodedQueueDepth: Int?
  public let maximumEncodedQueueDepth: Int?
  public let encodedQueueCapacity: Int?
  public let encodedQueueFinalized: Bool
  public let writerMetricSamples: Int
  public let writerCycles: UInt64
  public let subscriberDispatches: UInt64
  public let dispatchWallTotalUS: UInt64
  public let maximumDispatchWallUS: UInt64
  public let confirmationWaitTotalUS: UInt64
  public let maximumConfirmationWaitUS: UInt64
  public let completedConfirmations: UInt64
  public let timedOutConfirmations: UInt64
  public let writerTimingFinalized: Bool
  public let networkMetricSamples: Int
  public let networkSubscriberCount: Int
  public let qosSubscriberCount: Int
  public let delaySampledSubscribers: Int
  public let rttSampledSubscribers: Int
  public let responseDelayedSubscribers: Int
  public let networkDelayMS: Int?
  public let maximumNetworkDelayMS: Int?
  public let roundTripTimeMS: Int?
  public let maximumRoundTripTimeMS: Int?
  public let networkMetricsFinalized: Bool
  public let transportMetricSamples: Int
  public let transportSubscriberCount: Int
  public let directSubscribers: Int
  public let relaySubscribers: Int
  public let unknownSubscribers: Int
  public let transportMetricsFinalized: Bool
  public let drops: HostMediaDropCounts
  public let hardwareAccelerated: Bool?
  public let softwareFallback: Bool?
  public let encoderID: String?
  public let processSamples: Int
  public let processCPUPercent: Double?
  public let peakProcessCPUPercent: Double
  public let residentBytes: UInt64?
  public let peakResidentBytes: UInt64
  public let physicalFootprintBytes: UInt64?
  public let peakPhysicalFootprintBytes: UInt64
  public let threadCount: Int?
  public let peakThreadCount: Int
  public let thermalState: String?
  public let powerSource: String?
  public let lowPowerModeEnabled: Bool?
  public let runtimeSeconds: Double
}

/// Per-route bounded Host metrics. It also forwards every stage to the
/// production signpost recorder (or a test recorder), keeping measurement and
/// Instruments correlation on the same event boundary.
public final class HostMediaTelemetry: HostMediaStageRecording, @unchecked Sendable {
  private static let maximumLatencySamples = 2_048
  private static let maximumTrackedEncodeLatencies = 512
  private static let maximumSendOutcomeSamples = 32
  private static let recentEventWindowNS: UInt64 = 5_000_000_000
  private static let maximumRecentEventSamples = 1_202

  private let configuration: HostMediaPipelineConfiguration
  private let downstream: any HostMediaStageRecording
  private let lock = NSLock()
  private let startedAtNS = DispatchTime.now().uptimeNanoseconds
  private let processSampler = HostProcessSampler()
  private let processQueue = DispatchQueue(
    label: "io.farpane.host-process-telemetry",
    qos: .utility
  )
  private var processTimer: DispatchSourceTimer?

  private var captureWidth: Int?
  private var captureHeight: Int?
  private var pixelFormat: String?
  private var captureCallbacks = 0
  private var validFrames = 0
  private var firstValidFrameNS: UInt64?
  private var lastValidFrameNS: UInt64?
  private var recentCaptureTimestampsNS: [UInt64] = []
  private var nextRecentCaptureTimestampIndex = 0
  private var captureContentState = HostCaptureContentState.highMotion
  private var captureTargetFPS: Int
  private var captureAppliedFPS: Int
  private var captureDirtyMetadataTrusted = false
  private var capturePressureLevel = HostCapturePressureLevel.none
  private var captureCadenceTransitions = 0
  private var capturePressureTransitions = 0
  private var captureConfigurationUpdateAttempts = 0
  private var captureConfigurationUpdatesApplied = 0
  private var captureConfigurationUpdateFailures = 0
  private var captureConfigurationUpdateCancellations = 0
  private var captureConfigurationUpdateInFlight = false
  private var latestDirtyAreaRatio: Double?
  private var dirtyAreaRatioSum = 0.0
  private var dirtyAreaRatioSamples = 0
  private var maximumLogicalRawFrameCopyCount = 0
  private var rawFrameQueueDepth = 0
  private var maximumRawFrameQueueDepth = 0
  private var encodeSubmissions = 0
  private var encodeRejected = 0
  private var encodedPackets = 0
  private var recentEncodedTimestampsNS: [UInt64] = []
  private var nextRecentEncodedTimestampIndex = 0
  private var encodeInFlight = 0
  private var maximumEncodeInFlight = 0
  private var encodeStartedAtByPTS: [UInt64: UInt64] = [:]
  private var encodeLatencyTrackingEvictions = 0
  private var encodeLatencySamplesMS: [Double] = []
  private var nextLatencySampleIndex = 0
  private var latestEncodeLatencyMS: Double?
  private var encodedBytes: UInt64 = 0
  private var keyframes = 0
  private var sendSubmissions = 0
  private var sendAccepted = 0
  private var recentSendAcceptedTimestampsNS: [UInt64] = []
  private var nextRecentSendAcceptedTimestampIndex = 0
  private var sendDropped = 0
  private var sendOutcomeSamples: [Bool] = []
  private var nextSendOutcomeSampleIndex = 0
  private var consecutiveSendDrops = 0
  private var encodedQueueSamples = 0
  private var encodedQueueDepth: Int?
  private var maximumEncodedQueueDepth: Int?
  private var encodedQueueCapacity: Int?
  private var consecutiveEncodedQueueNearFullSamples = 0
  private var encodedQueueFinalized = false
  private var writerMetricSamples = 0
  private var writerCycles: UInt64 = 0
  private var subscriberDispatches: UInt64 = 0
  private var dispatchWallTotalUS: UInt64 = 0
  private var maximumDispatchWallUS: UInt64 = 0
  private var confirmationWaitTotalUS: UInt64 = 0
  private var maximumConfirmationWaitUS: UInt64 = 0
  private var completedConfirmations: UInt64 = 0
  private var timedOutConfirmations: UInt64 = 0
  private var writerTimingFinalized = false
  private var networkMetricSamples = 0
  private var networkSubscriberCount = 0
  private var qosSubscriberCount = 0
  private var delaySampledSubscribers = 0
  private var rttSampledSubscribers = 0
  private var responseDelayedSubscribers = 0
  private var networkDelayMS: Int?
  private var maximumNetworkDelayMS: Int?
  private var roundTripTimeMS: Int?
  private var maximumRoundTripTimeMS: Int?
  private var networkMetricsFinalized = false
  private var transportMetricSamples = 0
  private var transportSubscriberCount = 0
  private var directSubscribers = 0
  private var relaySubscribers = 0
  private var unknownSubscribers = 0
  private var transportMetricsFinalized = false
  private var instrumentedDropReasons: Set<HostMediaDropReason> = []
  private var dropCounts: [HostMediaDropReason: Int] = [:]
  private var unclassifiedDrops = 0
  private var hardwareAccelerated: Bool?
  private var softwareFallback: Bool?
  private var encoderID: String?
  private var processSamples = 0
  private var processCPUPercent: Double?
  private var peakProcessCPUPercent = 0.0
  private var residentBytes: UInt64?
  private var peakResidentBytes: UInt64 = 0
  private var physicalFootprintBytes: UInt64?
  private var peakPhysicalFootprintBytes: UInt64 = 0
  private var threadCount: Int?
  private var peakThreadCount = 0
  private var thermalState: String?
  private var powerSource: String?
  private var lowPowerModeEnabled: Bool?

  public init(
    configuration: HostMediaPipelineConfiguration,
    stageRecorder: any HostMediaStageRecording = HostMediaSignpostRecorder.shared
  ) {
    self.configuration = configuration
    self.downstream = stageRecorder
    self.captureTargetFPS = configuration.framesPerSecond
    self.captureAppliedFPS = configuration.framesPerSecond
    startProcessSampling()
  }

  deinit {
    processTimer?.setEventHandler {}
    processTimer?.cancel()
  }

  public func recordCaptureCallback() {
    locked { captureCallbacks += 1 }
  }

  public func recordCapturedFrame(_ frame: HostCapturedFrame) {
    recordCapturedFrame(frame, nowNS: DispatchTime.now().uptimeNanoseconds)
  }

  func recordCapturedFrame(_ frame: HostCapturedFrame, nowNS: UInt64) {
    let width = CVPixelBufferGetWidth(frame.pixelBuffer)
    let height = CVPixelBufferGetHeight(frame.pixelBuffer)
    let format = Self.fourCC(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))
    locked {
      captureWidth = width
      captureHeight = height
      pixelFormat = format
      validFrames += 1
      if firstValidFrameNS == nil { firstValidFrameNS = nowNS }
      lastValidFrameNS = nowNS
      appendRecentCaptureTimestamp(nowNS)
      maximumLogicalRawFrameCopyCount = max(
        maximumLogicalRawFrameCopyCount,
        frame.logicalRawFrameCopyCount
      )
      if let ratio = frame.dirtyAreaRatio {
        latestDirtyAreaRatio = ratio
        dirtyAreaRatioSum += ratio
        dirtyAreaRatioSamples += 1
      }
    }
  }

  func recordCaptureCadence(_ event: HostCaptureCadenceEvent) {
    locked {
      switch event {
      case .decision(let decision):
        if captureContentState != decision.contentState {
          captureCadenceTransitions += 1
        }
        captureContentState = decision.contentState
        captureTargetFPS = decision.framesPerSecond
        captureDirtyMetadataTrusted = decision.dirtyMetadataTrusted
        if capturePressureLevel != decision.pressureLevel {
          capturePressureTransitions += 1
        }
        capturePressureLevel = decision.pressureLevel
      case .configurationSubmitted(let framesPerSecond):
        captureTargetFPS = framesPerSecond
        captureConfigurationUpdateAttempts += 1
        captureConfigurationUpdateInFlight = true
      case .configurationApplied(let framesPerSecond):
        captureAppliedFPS = framesPerSecond
        captureConfigurationUpdatesApplied += 1
        captureConfigurationUpdateInFlight = false
      case .configurationFailed:
        captureConfigurationUpdateFailures += 1
        captureConfigurationUpdateInFlight = false
      case .configurationCancelled:
        captureConfigurationUpdateCancellations += 1
        captureConfigurationUpdateInFlight = false
      }
    }
  }

  public func recordPacket(
    presentationTimeUS: UInt64,
    byteCount: Int,
    isKeyframe: Bool
  ) {
    recordPacket(
      presentationTimeUS: presentationTimeUS,
      byteCount: byteCount,
      isKeyframe: isKeyframe,
      nowNS: DispatchTime.now().uptimeNanoseconds
    )
  }

  func recordPacket(
    presentationTimeUS: UInt64,
    byteCount: Int,
    isKeyframe: Bool,
    nowNS: UInt64
  ) {
    locked {
      encodedPackets += 1
      Self.appendRecentEventTimestamp(
        nowNS,
        timestampsNS: &recentEncodedTimestampsNS,
        nextIndex: &nextRecentEncodedTimestampIndex
      )
      encodedBytes &+= UInt64(max(0, byteCount))
      if isKeyframe { keyframes += 1 }
      let startedAt = encodeStartedAtByPTS.removeValue(forKey: presentationTimeUS)
      encodeInFlight = max(0, encodeInFlight - 1)
      if let startedAt {
        let latencyMS = Double(nowNS &- startedAt) / 1_000_000
        latestEncodeLatencyMS = latencyMS
        appendLatencySample(latencyMS)
      }
    }
  }

  public func recordEncoderState(_ state: HostEncoderRuntimeState) {
    locked {
      hardwareAccelerated = state.hardwareAccelerated
      softwareFallback = state.softwareFallback
      encoderID = state.encoderID
    }
  }

  /// A zero is evidence only after the production boundary declares that it
  /// can observe this reason. Uninstrumented reasons remain nil in snapshots.
  package func markDropReasonsInstrumented(_ reasons: [HostMediaDropReason]) {
    locked {
      for reason in reasons {
        instrumentedDropReasons.insert(reason)
        if dropCounts[reason] == nil { dropCounts[reason] = 0 }
      }
    }
  }

  package func recordDrop(_ reason: HostMediaDropReason, count: Int = 1) {
    locked { recordDropLocked(reason, count: count) }
  }

  package func recordEncoderDrop(
    presentationTimeUS: UInt64,
    reason: HostMediaDropReason
  ) {
    locked {
      encodeStartedAtByPTS.removeValue(forKey: presentationTimeUS)
      encodeInFlight = max(0, encodeInFlight - 1)
      recordDropLocked(reason, count: 1)
    }
  }

  package func recordRawFrameQueueDepth(_ depth: Int) {
    locked {
      rawFrameQueueDepth = max(0, depth)
      maximumRawFrameQueueDepth = max(
        maximumRawFrameQueueDepth,
        rawFrameQueueDepth
      )
    }
  }

  package func recordUnclassifiedDrop() {
    locked {
      if unclassifiedDrops < Int.max { unclassifiedDrops += 1 }
    }
  }

  func sampleProcessNow() {
    let sample = processSampler.sample()
    locked {
      processSamples += 1
      processCPUPercent = sample.cpuPercent
      peakProcessCPUPercent = max(peakProcessCPUPercent, sample.cpuPercent)
      residentBytes = sample.residentBytes
      peakResidentBytes = max(peakResidentBytes, sample.residentBytes)
      physicalFootprintBytes = sample.physicalFootprintBytes
      peakPhysicalFootprintBytes = max(
        peakPhysicalFootprintBytes,
        sample.physicalFootprintBytes
      )
      threadCount = sample.threadCount
      peakThreadCount = max(peakThreadCount, sample.threadCount)
      thermalState = sample.thermalState
      powerSource = sample.powerSource
      lowPowerModeEnabled = sample.lowPowerModeEnabled
    }
  }

  public func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int
  ) {
    record(
      stage,
      presentationTimeUS: presentationTimeUS,
      byteCount: byteCount,
      nowNS: DispatchTime.now().uptimeNanoseconds
    )
  }

  func record(
    _ stage: HostMediaStage,
    presentationTimeUS: UInt64,
    byteCount: Int,
    nowNS: UInt64
  ) {
    downstream.record(
      stage,
      presentationTimeUS: presentationTimeUS,
      byteCount: byteCount
    )
    locked {
      switch stage {
      case .capture:
        break
      case .encodeSubmit:
        encodeSubmissions += 1
        if encodeStartedAtByPTS[presentationTimeUS] == nil {
          if encodeStartedAtByPTS.count >= Self.maximumTrackedEncodeLatencies,
             let oldest = encodeStartedAtByPTS.min(by: { $0.value < $1.value })?.key {
            encodeStartedAtByPTS.removeValue(forKey: oldest)
            encodeLatencyTrackingEvictions += 1
          }
          encodeStartedAtByPTS[presentationTimeUS] = nowNS
          encodeInFlight += 1
          maximumEncodeInFlight = max(maximumEncodeInFlight, encodeInFlight)
        } else {
          encodeStartedAtByPTS[presentationTimeUS] = nowNS
        }
      case .encodeRejected:
        encodeRejected += 1
        encodeStartedAtByPTS.removeValue(forKey: presentationTimeUS)
        encodeInFlight = max(0, encodeInFlight - 1)
      case .packetReady:
        break
      case .sendSubmit:
        sendSubmissions += 1
      case .sendAccepted:
        sendAccepted += 1
        Self.appendRecentEventTimestamp(
          nowNS,
          timestampsNS: &recentSendAcceptedTimestampsNS,
          nextIndex: &nextRecentSendAcceptedTimestampIndex
        )
        appendSendOutcome(dropped: false)
        consecutiveSendDrops = 0
      case .sendDropped:
        sendDropped += 1
        appendSendOutcome(dropped: true)
        if consecutiveSendDrops < Int.max { consecutiveSendDrops += 1 }
      }
    }
  }

  func captureBackpressure() -> HostCaptureBackpressure {
    locked { captureBackpressureLocked }
  }

  private var captureBackpressureLocked: HostCaptureBackpressure {
    HostCaptureBackpressure(
      encodeInFlight: encodeInFlight,
      latestEncodeLatencyMS: latestEncodeLatencyMS,
      recentSendOutcomeCount: sendOutcomeSamples.count,
      recentSendDropRate: recentSendDropRate,
      consecutiveSendDrops: consecutiveSendDrops,
      encodedQueueDepth: encodedQueueDepth,
      encodedQueueCapacity: encodedQueueCapacity,
      consecutiveEncodedQueueNearFullSamples: consecutiveEncodedQueueNearFullSamples,
      networkDelayMS: networkDelayMS,
      roundTripTimeMS: roundTripTimeMS,
      responseDelayedSubscribers: networkMetricSamples > 0
        ? responseDelayedSubscribers
        : nil,
      thermalState: thermalState,
      lowPowerModeEnabled: lowPowerModeEnabled
    )
  }

  /// Records only validated aggregate occupancy from the production Rust
  /// queue. A capacity change inside one route is rejected instead of merging
  /// incomparable samples into a plausible-looking metric.
  @discardableResult
  public func recordEncodedQueueDepth(
    current: Int,
    maximum: Int,
    capacity: Int,
    finalized: Bool
  ) -> Bool {
    guard capacity > 0,
          current >= 0,
          current <= maximum,
          maximum <= capacity
    else { return false }
    return locked {
      guard encodedQueueCapacity == nil || encodedQueueCapacity == capacity else {
        return false
      }
      if encodedQueueSamples < Int.max { encodedQueueSamples += 1 }
      encodedQueueDepth = current
      maximumEncodedQueueDepth = max(maximumEncodedQueueDepth ?? 0, maximum)
      encodedQueueCapacity = capacity
      let nearFull = current < capacity && current >= max(1, capacity - 1)
      if nearFull {
        if consecutiveEncodedQueueNearFullSamples < Int.max {
          consecutiveEncodedQueueNearFullSamples += 1
        }
      } else {
        consecutiveEncodedQueueNearFullSamples = 0
      }
      encodedQueueFinalized = encodedQueueFinalized || finalized
      return true
    }
  }

  /// Records cumulative route-scoped wall measurements emitted by the Rust
  /// video-service loop. Regressing or internally inconsistent samples are
  /// rejected rather than merged into plausible-looking evidence.
  @discardableResult
  public func recordWriterTiming(
    cycles: UInt64,
    subscriberDispatches: UInt64,
    dispatchWallTotalUS: UInt64,
    maximumDispatchWallUS: UInt64,
    confirmationWaitTotalUS: UInt64,
    maximumConfirmationWaitUS: UInt64,
    completedConfirmations: UInt64,
    timedOutConfirmations: UInt64,
    finalized: Bool
  ) -> Bool {
    let (confirmationCycles, overflow) = completedConfirmations.addingReportingOverflow(
      timedOutConfirmations
    )
    guard !overflow,
          confirmationCycles == cycles,
          maximumDispatchWallUS <= dispatchWallTotalUS,
          maximumConfirmationWaitUS <= confirmationWaitTotalUS,
          (cycles == 0
            ? subscriberDispatches == 0
              && dispatchWallTotalUS == 0
              && maximumDispatchWallUS == 0
              && confirmationWaitTotalUS == 0
              && maximumConfirmationWaitUS == 0
            : subscriberDispatches >= cycles)
    else { return false }
    return locked {
      guard !writerTimingFinalized,
            cycles >= writerCycles,
            subscriberDispatches >= self.subscriberDispatches,
            dispatchWallTotalUS >= self.dispatchWallTotalUS,
            maximumDispatchWallUS >= self.maximumDispatchWallUS,
            confirmationWaitTotalUS >= self.confirmationWaitTotalUS,
            maximumConfirmationWaitUS >= self.maximumConfirmationWaitUS,
            completedConfirmations >= self.completedConfirmations,
            timedOutConfirmations >= self.timedOutConfirmations
      else { return false }
      if writerMetricSamples < Int.max { writerMetricSamples += 1 }
      writerCycles = cycles
      self.subscriberDispatches = subscriberDispatches
      self.dispatchWallTotalUS = dispatchWallTotalUS
      self.maximumDispatchWallUS = maximumDispatchWallUS
      self.confirmationWaitTotalUS = confirmationWaitTotalUS
      self.maximumConfirmationWaitUS = maximumConfirmationWaitUS
      self.completedConfirmations = completedConfirmations
      self.timedOutConfirmations = timedOutConfirmations
      writerTimingFinalized = finalized
      return true
    }
  }

  /// Records a route-scoped RustDesk QoS snapshot. Counts and optional sample
  /// availability must agree; fluctuating delay/RTT values are retained as
  /// latest plus route maximum, and no sample may arrive after finalization.
  @discardableResult
  public func recordNetworkMetrics(
    subscriberCount: Int,
    qosSubscriberCount: Int,
    delaySampledSubscribers: Int,
    rttSampledSubscribers: Int,
    responseDelayedSubscribers: Int,
    networkDelayMS: Int?,
    roundTripTimeMS: Int?,
    finalized: Bool
  ) -> Bool {
    guard subscriberCount >= 0,
          qosSubscriberCount >= 0,
          qosSubscriberCount <= subscriberCount,
          delaySampledSubscribers >= 0,
          delaySampledSubscribers <= qosSubscriberCount,
          rttSampledSubscribers >= 0,
          rttSampledSubscribers <= delaySampledSubscribers,
          responseDelayedSubscribers >= 0,
          responseDelayedSubscribers <= qosSubscriberCount,
          (delaySampledSubscribers == 0) == (networkDelayMS == nil),
          (rttSampledSubscribers == 0) == (roundTripTimeMS == nil),
          networkDelayMS.map({ $0 >= 0 }) ?? true,
          roundTripTimeMS.map({ $0 >= 0 }) ?? true
    else { return false }
    return locked {
      guard !networkMetricsFinalized else { return false }
      if networkMetricSamples < Int.max { networkMetricSamples += 1 }
      networkSubscriberCount = subscriberCount
      self.qosSubscriberCount = qosSubscriberCount
      self.delaySampledSubscribers = delaySampledSubscribers
      self.rttSampledSubscribers = rttSampledSubscribers
      self.responseDelayedSubscribers = responseDelayedSubscribers
      self.networkDelayMS = networkDelayMS
      if let networkDelayMS {
        maximumNetworkDelayMS = max(maximumNetworkDelayMS ?? 0, networkDelayMS)
      }
      self.roundTripTimeMS = roundTripTimeMS
      if let roundTripTimeMS {
        maximumRoundTripTimeMS = max(maximumRoundTripTimeMS ?? 0, roundTripTimeMS)
      }
      networkMetricsFinalized = finalized
      return true
    }
  }

  /// Records the latest authoritative connection transport mix for the exact
  /// display route. Counts must partition the subscriber set completely;
  /// unknown remains explicit and no sample may arrive after finalization.
  @discardableResult
  public func recordTransportMetrics(
    subscriberCount: Int,
    directSubscribers: Int,
    relaySubscribers: Int,
    unknownSubscribers: Int,
    finalized: Bool
  ) -> Bool {
    guard subscriberCount >= 0,
          directSubscribers >= 0,
          relaySubscribers >= 0,
          unknownSubscribers >= 0
    else { return false }
    let (classifiedSubscribers, firstOverflow) = directSubscribers.addingReportingOverflow(
      relaySubscribers
    )
    let (allSubscribers, secondOverflow) = classifiedSubscribers.addingReportingOverflow(
      unknownSubscribers
    )
    guard !firstOverflow,
          !secondOverflow,
          allSubscribers == subscriberCount
    else { return false }
    return locked {
      guard !transportMetricsFinalized else { return false }
      if transportMetricSamples < Int.max { transportMetricSamples += 1 }
      transportSubscriberCount = subscriberCount
      self.directSubscribers = directSubscribers
      self.relaySubscribers = relaySubscribers
      self.unknownSubscribers = unknownSubscribers
      transportMetricsFinalized = finalized
      return true
    }
  }

  public func snapshot() -> HostMediaTelemetrySnapshot {
    snapshot(nowNS: DispatchTime.now().uptimeNanoseconds)
  }

  func snapshot(nowNS: UInt64) -> HostMediaTelemetrySnapshot {
    return locked {
      let runtimeSeconds = Self.seconds(from: startedAtNS, to: nowNS)
      let actualFPS: Double
      if validFrames > 1,
         let firstValidFrameNS,
         let lastValidFrameNS,
         lastValidFrameNS > firstValidFrameNS {
        actualFPS = Double(validFrames - 1)
          / Self.seconds(from: firstValidFrameNS, to: lastValidFrameNS)
      } else {
        actualFPS = 0
      }
      let recentCaptureFPS = Self.recentEventsPerSecond(
        timestampsNS: recentCaptureTimestampsNS,
        nowNS: nowNS
      )
      let recentEncodedFPS = Self.recentEventsPerSecond(
        timestampsNS: recentEncodedTimestampsNS,
        nowNS: nowNS
      )
      let recentSendAcceptedFPS = Self.recentEventsPerSecond(
        timestampsNS: recentSendAcceptedTimestampsNS,
        nowNS: nowNS
      )
      let pressureAssessment = captureBackpressureLocked.assessment(
        maximumFramesPerSecond: configuration.framesPerSecond
      )
      let sortedLatencies = encodeLatencySamplesMS.sorted()
      let classifiedDrops = dropCounts.values.reduce(0) { partial, count in
        let (sum, overflow) = partial.addingReportingOverflow(count)
        return overflow ? Int.max : sum
      }
      return HostMediaTelemetrySnapshot(
        codec: configuration.codec,
        requestedWidth: configuration.width,
        requestedHeight: configuration.height,
        requestedFPS: configuration.framesPerSecond,
        captureWidth: captureWidth,
        captureHeight: captureHeight,
        pixelFormat: pixelFormat,
        captureCallbacks: captureCallbacks,
        validFrames: validFrames,
        actualFPS: actualFPS,
        recentCaptureFPS: recentCaptureFPS,
        recentEncodedFPS: recentEncodedFPS,
        recentSendAcceptedFPS: recentSendAcceptedFPS,
        captureContentState: captureContentState,
        captureTargetFPS: captureTargetFPS,
        captureAppliedFPS: captureAppliedFPS,
        captureDirtyMetadataTrusted: captureDirtyMetadataTrusted,
        capturePressureLevel: capturePressureLevel,
        captureObservedPressureLevel: pressureAssessment.level,
        capturePressureCauses: pressureAssessment.causes,
        captureCadenceTransitions: captureCadenceTransitions,
        capturePressureTransitions: capturePressureTransitions,
        captureConfigurationUpdateAttempts: captureConfigurationUpdateAttempts,
        captureConfigurationUpdatesApplied: captureConfigurationUpdatesApplied,
        captureConfigurationUpdateFailures: captureConfigurationUpdateFailures,
        captureConfigurationUpdateCancellations: captureConfigurationUpdateCancellations,
        captureConfigurationUpdateInFlight: captureConfigurationUpdateInFlight,
        latestDirtyAreaRatio: latestDirtyAreaRatio,
        averageDirtyAreaRatio: dirtyAreaRatioSamples > 0
          ? dirtyAreaRatioSum / Double(dirtyAreaRatioSamples)
          : nil,
        maximumLogicalRawFrameCopyCount: maximumLogicalRawFrameCopyCount,
        rawFrameQueueDepth: rawFrameQueueDepth,
        maximumRawFrameQueueDepth: maximumRawFrameQueueDepth,
        encodeSubmissions: encodeSubmissions,
        encodeRejected: encodeRejected,
        encodedPackets: encodedPackets,
        encodeInFlight: encodeInFlight,
        maximumEncodeInFlight: maximumEncodeInFlight,
        trackedEncodeLatencies: encodeStartedAtByPTS.count,
        encodeLatencyTrackingEvictions: encodeLatencyTrackingEvictions,
        encodeLatencyP50MS: Self.percentile(0.50, sorted: sortedLatencies),
        encodeLatencyP95MS: Self.percentile(0.95, sorted: sortedLatencies),
        encodeLatencyP99MS: Self.percentile(0.99, sorted: sortedLatencies),
        latestEncodeLatencyMS: latestEncodeLatencyMS,
        encodedBytes: encodedBytes,
        encodedBitRateBPS: runtimeSeconds > 0
          ? Double(encodedBytes) * 8 / runtimeSeconds
          : 0,
        keyframes: keyframes,
        sendSubmissions: sendSubmissions,
        sendAccepted: sendAccepted,
        sendDropped: sendDropped,
        recentSendOutcomeCount: sendOutcomeSamples.count,
        recentSendDropRate: recentSendDropRate,
        consecutiveSendDrops: consecutiveSendDrops,
        encodedQueueSamples: encodedQueueSamples,
        encodedQueueDepth: encodedQueueDepth,
        maximumEncodedQueueDepth: maximumEncodedQueueDepth,
        encodedQueueCapacity: encodedQueueCapacity,
        encodedQueueFinalized: encodedQueueFinalized,
        writerMetricSamples: writerMetricSamples,
        writerCycles: writerCycles,
        subscriberDispatches: subscriberDispatches,
        dispatchWallTotalUS: dispatchWallTotalUS,
        maximumDispatchWallUS: maximumDispatchWallUS,
        confirmationWaitTotalUS: confirmationWaitTotalUS,
        maximumConfirmationWaitUS: maximumConfirmationWaitUS,
        completedConfirmations: completedConfirmations,
        timedOutConfirmations: timedOutConfirmations,
        writerTimingFinalized: writerTimingFinalized,
        networkMetricSamples: networkMetricSamples,
        networkSubscriberCount: networkSubscriberCount,
        qosSubscriberCount: qosSubscriberCount,
        delaySampledSubscribers: delaySampledSubscribers,
        rttSampledSubscribers: rttSampledSubscribers,
        responseDelayedSubscribers: responseDelayedSubscribers,
        networkDelayMS: networkDelayMS,
        maximumNetworkDelayMS: maximumNetworkDelayMS,
        roundTripTimeMS: roundTripTimeMS,
        maximumRoundTripTimeMS: maximumRoundTripTimeMS,
        networkMetricsFinalized: networkMetricsFinalized,
        transportMetricSamples: transportMetricSamples,
        transportSubscriberCount: transportSubscriberCount,
        directSubscribers: directSubscribers,
        relaySubscribers: relaySubscribers,
        unknownSubscribers: unknownSubscribers,
        transportMetricsFinalized: transportMetricsFinalized,
        drops: HostMediaDropCounts(
          captureSuperseded: instrumentedCount(for: .captureSuperseded),
          encoderBackpressure: instrumentedCount(for: .encoderBackpressure),
          networkBackpressure: instrumentedCount(for: .networkBackpressure),
          reconfigure: instrumentedCount(for: .reconfigure),
          invalidFrame: instrumentedCount(for: .invalidFrame),
          shutdown: instrumentedCount(for: .shutdown),
          classified: classifiedDrops,
          unclassified: unclassifiedDrops
        ),
        hardwareAccelerated: hardwareAccelerated,
        softwareFallback: softwareFallback,
        encoderID: encoderID,
        processSamples: processSamples,
        processCPUPercent: processCPUPercent,
        peakProcessCPUPercent: peakProcessCPUPercent,
        residentBytes: residentBytes,
        peakResidentBytes: peakResidentBytes,
        physicalFootprintBytes: physicalFootprintBytes,
        peakPhysicalFootprintBytes: peakPhysicalFootprintBytes,
        threadCount: threadCount,
        peakThreadCount: peakThreadCount,
        thermalState: thermalState,
        powerSource: powerSource,
        lowPowerModeEnabled: lowPowerModeEnabled,
        runtimeSeconds: runtimeSeconds
      )
    }
  }

  private func appendLatencySample(_ milliseconds: Double) {
    if encodeLatencySamplesMS.count < Self.maximumLatencySamples {
      encodeLatencySamplesMS.append(milliseconds)
      return
    }
    encodeLatencySamplesMS[nextLatencySampleIndex] = milliseconds
    nextLatencySampleIndex = (nextLatencySampleIndex + 1) % Self.maximumLatencySamples
  }

  private func appendRecentCaptureTimestamp(_ timestampNS: UInt64) {
    Self.appendRecentEventTimestamp(
      timestampNS,
      timestampsNS: &recentCaptureTimestampsNS,
      nextIndex: &nextRecentCaptureTimestampIndex
    )
  }

  private static func appendRecentEventTimestamp(
    _ timestampNS: UInt64,
    timestampsNS: inout [UInt64],
    nextIndex: inout Int
  ) {
    if timestampsNS.count < maximumRecentEventSamples {
      timestampsNS.append(timestampNS)
      return
    }
    timestampsNS[nextIndex] = timestampNS
    nextIndex = (nextIndex + 1) % maximumRecentEventSamples
  }

  private static func recentEventsPerSecond(
    timestampsNS: [UInt64],
    nowNS: UInt64
  ) -> Double {
    let cutoff = nowNS > recentEventWindowNS
      ? nowNS - recentEventWindowNS
      : 0
    var sampleCount = 0
    var oldestTimestampNS = nowNS
    for timestampNS in timestampsNS
      where timestampNS >= cutoff && timestampNS <= nowNS {
      sampleCount += 1
      oldestTimestampNS = min(oldestTimestampNS, timestampNS)
    }
    guard sampleCount > 1, nowNS > oldestTimestampNS else { return 0 }
    return Double(sampleCount - 1)
      / Self.seconds(from: oldestTimestampNS, to: nowNS)
  }

  private func appendSendOutcome(dropped: Bool) {
    if sendOutcomeSamples.count < Self.maximumSendOutcomeSamples {
      sendOutcomeSamples.append(dropped)
      return
    }
    sendOutcomeSamples[nextSendOutcomeSampleIndex] = dropped
    nextSendOutcomeSampleIndex =
      (nextSendOutcomeSampleIndex + 1) % Self.maximumSendOutcomeSamples
  }

  private var recentSendDropRate: Double {
    guard !sendOutcomeSamples.isEmpty else { return 0 }
    let drops = sendOutcomeSamples.reduce(0) { count, dropped in
      count + (dropped ? 1 : 0)
    }
    return Double(drops) / Double(sendOutcomeSamples.count)
  }

  private func instrumentedCount(for reason: HostMediaDropReason) -> Int? {
    guard instrumentedDropReasons.contains(reason) else { return nil }
    return dropCounts[reason] ?? 0
  }

  private func recordDropLocked(_ reason: HostMediaDropReason, count: Int) {
    instrumentedDropReasons.insert(reason)
    let increment = max(0, count)
    let current = dropCounts[reason, default: 0]
    let (sum, overflow) = current.addingReportingOverflow(increment)
    dropCounts[reason] = overflow ? Int.max : sum
  }

  private func startProcessSampling() {
    let timer = DispatchSource.makeTimerSource(queue: processQueue)
    timer.schedule(
      deadline: .now() + .seconds(1),
      repeating: .seconds(1),
      leeway: .milliseconds(100)
    )
    timer.setEventHandler { [weak self] in self?.sampleProcessNow() }
    processTimer = timer
    timer.resume()
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func seconds(from start: UInt64, to end: UInt64) -> Double {
    Double(end &- start) / 1_000_000_000
  }

  private static func percentile(_ value: Double, sorted samples: [Double]) -> Double? {
    guard !samples.isEmpty else { return nil }
    let rank = Int(ceil(value * Double(samples.count))) - 1
    return samples[min(max(0, rank), samples.count - 1)]
  }

  private static func fourCC(_ value: OSType) -> String {
    let bytes: [UInt8] = [
      UInt8((value >> 24) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
  }
}
