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

public struct HostCaptureFrameStatusCounts: Equatable, Sendable {
    public let complete: Int
    public let idle: Int
    public let blank: Int
    public let suspended: Int
    public let started: Int
    public let stopped: Int
    public let missingOrInvalid: Int
    public let unknown: Int

    public var total: Int {
        [complete, idle, blank, suspended, started, stopped, missingOrInvalid, unknown].reduce(0, +)
    }
}

public struct HostCaptureDirtyRectsAttachmentCounts: Equatable, Sendable {
    public let absent: Int
    public let unrecognized: Int
    public let recognizedEmpty: Int
    public let recognizedNonEmpty: Int

    public var total: Int { absent + unrecognized + recognizedEmpty + recognizedNonEmpty }
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
    package let captureRecovery: HostCaptureRecoveryDiagnostics
    public let captureFrameStatusCounts: HostCaptureFrameStatusCounts
    public let captureCompleteDirtyRectsCounts: HostCaptureDirtyRectsAttachmentCounts
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
