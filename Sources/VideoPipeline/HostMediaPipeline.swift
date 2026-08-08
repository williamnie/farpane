import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

public enum HostPipelineCodec: String, Equatable, Sendable {
  case h264
  case h265
}

public struct HostMediaAccessUnit: Sendable {
  public let codec: HostPipelineCodec
  public let data: Data
  public let presentationTimeUS: UInt64
  public let isKeyframe: Bool
  public let hasParameterSets: Bool
  public let logicalRawFrameCopyCount: Int
}

public struct HostMediaPipelineConfiguration: Sendable {
  public let codec: HostPipelineCodec
  public let displayIndex: Int
  public let width: Int
  public let height: Int
  public let framesPerSecond: Int
  public let bitRate: Int

  public init(
    codec: HostPipelineCodec = .h264,
    displayIndex: Int,
    width: Int,
    height: Int,
    framesPerSecond: Int,
    bitRate: Int
  ) {
    self.codec = codec
    self.displayIndex = displayIndex
    self.width = width
    self.height = height
    self.framesPerSecond = framesPerSecond
    self.bitRate = bitRate
  }
}

struct HostMediaEncoderGenerationGate: Equatable, Sendable {
  private(set) var current: UInt64 = 0

  mutating func beginEncoder() -> UInt64 {
    current &+= 1
    return current
  }

  mutating func invalidateCurrent() {
    current &+= 1
  }

  func accepts(_ generation: UInt64) -> Bool {
    generation == current
  }
}

struct HostRawFrameHandoffEnqueueResult: Equatable, Sendable {
  let shouldScheduleWorker: Bool
  let supersededPendingFrame: Bool
  let depth: Int
}

struct HostRawFrameHandoffCancelResult: Equatable, Sendable {
  let cancelledPendingFrames: Int
  let depth: Int
}

/// Capacity includes the frame currently being handed to VideoToolbox plus
/// frames still waiting. Once a frame is active it is never replaced; when
/// full, only the oldest not-yet-submitted pending frame is superseded.
struct HostRawFrameHandoff<Element> {
  static var capacity: Int { 2 }

  private var pending: [Element] = []
  private var workerScheduled = false
  private var activeFrame = false

  var depth: Int { pending.count + (activeFrame ? 1 : 0) }

  mutating func enqueue(_ element: Element) -> HostRawFrameHandoffEnqueueResult {
    var superseded = false
    if depth >= Self.capacity {
      precondition(!pending.isEmpty)
      pending.removeFirst()
      superseded = true
    }
    pending.append(element)
    let shouldScheduleWorker = !workerScheduled
    if shouldScheduleWorker { workerScheduled = true }
    return HostRawFrameHandoffEnqueueResult(
      shouldScheduleWorker: shouldScheduleWorker,
      supersededPendingFrame: superseded,
      depth: depth
    )
  }

  mutating func beginNext() -> Element? {
    precondition(!activeFrame)
    guard !pending.isEmpty else {
      workerScheduled = false
      return nil
    }
    activeFrame = true
    return pending.removeFirst()
  }

  mutating func finishActive() -> Int {
    precondition(activeFrame)
    activeFrame = false
    return depth
  }

  mutating func cancelPending() -> HostRawFrameHandoffCancelResult {
    let cancelled = pending.count
    pending.removeAll(keepingCapacity: true)
    return HostRawFrameHandoffCancelResult(
      cancelledPendingFrames: cancelled,
      depth: depth
    )
  }
}

private struct HostQueuedCapturedFrame: @unchecked Sendable {
  let frame: HostCapturedFrame
  let presentationTime: CMTime
  let presentationTimeUS: UInt64
}

private enum HostMediaActiveEncoder: Sendable {
  case h264(HostH264Encoder)
  case h265(HostHEVCEncoder)

  func requestKeyframe() {
    switch self {
    case .h264(let encoder): encoder.requestKeyframe()
    case .h265(let encoder): encoder.requestKeyframe()
    }
  }

  func encode(frame: HostCapturedFrame, presentationTime: CMTime) throws {
    switch self {
    case .h264(let encoder):
      try encoder.encode(
        pixelBuffer: frame.pixelBuffer,
        presentationTime: presentationTime,
        logicalRawFrameCopyCount: frame.logicalRawFrameCopyCount
      )
    case .h265(let encoder):
      try encoder.encode(
        pixelBuffer: frame.pixelBuffer,
        presentationTime: presentationTime,
        logicalRawFrameCopyCount: frame.logicalRawFrameCopyCount
      )
    }
  }

  func invalidate() {
    switch self {
    case .h264(let encoder): encoder.invalidate()
    case .h265(let encoder): encoder.invalidate()
    }
  }
}

/// H1 single-display SCK → VideoToolbox pipeline. The selected codec creates
/// exactly one process-local encoder; only compressed AVCC access units cross
/// the Host Media ABI.
public final class HostMediaPipeline: @unchecked Sendable {
  public typealias AccessUnitHandler = @Sendable (HostMediaAccessUnit) -> Void
  public typealias StateHandler = @Sendable (HostEncoderRuntimeState) -> Void
  public typealias ErrorHandler = @Sendable (Error) -> Void

  private let configuration: HostMediaPipelineConfiguration
  private let lock = NSLock()
  private let encoderResetQueue = DispatchQueue(
    label: "io.farpane.host-encoder-reset",
    qos: .userInitiated
  )
  private let encoderQueue = DispatchQueue(
    label: "io.farpane.host-raw-frame-handoff",
    qos: .userInteractive
  )
  private let onAccessUnit: AccessUnitHandler
  private let onState: StateHandler
  private let onError: ErrorHandler
  public let telemetry: HostMediaTelemetry
  private var capture: HostScreenCaptureAdapter?
  private var encoder: HostMediaActiveEncoder?
  private var encoderGeneration = HostMediaEncoderGenerationGate()
  private var rawFrameHandoff = HostRawFrameHandoff<HostQueuedCapturedFrame>()
  private var firstPresentationTime: CMTime?
  private var active = false

  public init(
    configuration: HostMediaPipelineConfiguration,
    telemetry: HostMediaTelemetry? = nil,
    stageRecorder: any HostMediaStageRecording = HostMediaSignpostRecorder.shared,
    onAccessUnit: @escaping AccessUnitHandler,
    onState: @escaping StateHandler,
    onError: @escaping ErrorHandler
  ) {
    self.configuration = configuration
    self.telemetry = telemetry ?? HostMediaTelemetry(
      configuration: configuration,
      stageRecorder: stageRecorder
    )
    self.onAccessUnit = onAccessUnit
    self.onState = onState
    self.onError = onError
    self.telemetry.markDropReasonsInstrumented([
      .captureSuperseded,
      .encoderBackpressure,
      .reconfigure,
      .invalidFrame,
      .shutdown,
    ])
  }

  public func start() async throws {
    let capture = HostScreenCaptureAdapter(
      onFrame: { [weak self] frame in self?.enqueue(frame) },
      onSample: { [weak self] metadata in
        self?.telemetry.recordCaptureSample(metadata)
      },
      onDrop: { [weak self] reason in self?.telemetry.recordDrop(reason) },
      onCadence: { [weak self] event in self?.telemetry.recordCaptureCadence(event) },
      pressureProvider: { [weak self] in
        self?.telemetry.captureBackpressure() ?? .clear
      },
      onError: { [weak self] error in self?.onError(error) }
    )
    lock.withLock {
      active = true
      self.capture = capture
    }
    do {
      try await capture.start(
        configuration: HostCaptureConfiguration(
          displayIndex: configuration.displayIndex,
          width: configuration.width,
          height: configuration.height,
          framesPerSecond: configuration.framesPerSecond
        ))
    } catch {
      cancel()
      throw error
    }
  }

  public func requestKeyframe() {
    lock.withLock { encoder?.requestKeyframe() }
  }

  /// Drops the current encoder generation after an encoded packet could not
  /// enter the ordered Rust queue. Old callbacks are ignored at the submit
  /// boundary, while a fresh encoder starts with an IDR and parameter sets.
  /// CompleteFrames/invalidate runs away from the VideoToolbox callback to
  /// avoid reentrant waiting on the callback that requested recovery.
  public func recoverFromEncodedPacketDrop() {
    let encoder = lock.withLock { () -> HostMediaActiveEncoder? in
      guard active, let encoder = self.encoder else { return nil }
      encoderGeneration.invalidateCurrent()
      self.encoder = nil
      return encoder
    }
    guard let encoder else { return }
    encoderResetQueue.async { encoder.invalidate() }
  }

  /// Synchronously prevents any further encoded submission. Stream shutdown
  /// remains async but is safe to finish after the Rust route is removed.
  public func cancel() {
    let (capture, encoder, cancelledFrames) = lock.withLock {
      () -> (HostScreenCaptureAdapter?, HostMediaActiveEncoder?, Int) in
      active = false
      let capture = self.capture
      let value = self.encoder
      self.encoder = nil
      let cancelled = rawFrameHandoff.cancelPending()
      telemetry.recordRawFrameQueueDepth(cancelled.depth)
      return (capture, value, cancelled.cancelledPendingFrames)
    }
    telemetry.recordDrop(.shutdown, count: cancelledFrames)
    capture?.cancel()
    encoder?.invalidate()
  }

  public func stop() async {
    cancel()
    let capture = lock.withLock { () -> HostScreenCaptureAdapter? in
      let value = self.capture
      self.capture = nil
      return value
    }
    await capture?.stop()
    encoderQueue.sync {}
    encoderResetQueue.sync {}
  }

  private func enqueue(_ frame: HostCapturedFrame) {
    telemetry.recordCapturedFrame(frame)
    let result = lock.withLock {
      () -> (HostRawFrameHandoffEnqueueResult, UInt64)? in
      guard active else { return nil }
      if firstPresentationTime == nil { firstPresentationTime = frame.presentationTime }
      let presentationTime = CMTimeSubtract(frame.presentationTime, firstPresentationTime!)
      let presentationTimeUS = UInt64(max(
        0,
        CMTimeConvertScale(
          presentationTime,
          timescale: 1_000_000,
          method: .default
        ).value
      ))
      let result = rawFrameHandoff.enqueue(HostQueuedCapturedFrame(
        frame: frame,
        presentationTime: presentationTime,
        presentationTimeUS: presentationTimeUS
      ))
      telemetry.recordRawFrameQueueDepth(result.depth)
      return (result, presentationTimeUS)
    }
    guard let (enqueueResult, presentationTimeUS) = result else {
      telemetry.recordDrop(.shutdown)
      return
    }
    telemetry.record(
      .capture,
      presentationTimeUS: presentationTimeUS,
      byteCount: 0
    )
    if enqueueResult.supersededPendingFrame {
      telemetry.recordDrop(.captureSuperseded)
    }
    if enqueueResult.shouldScheduleWorker {
      encoderQueue.async { [weak self] in self?.drainRawFrames() }
    }
  }

  private func drainRawFrames() {
    while let queuedFrame = lock.withLock({ rawFrameHandoff.beginNext() }) {
      consume(queuedFrame)
      lock.withLock {
        let depth = rawFrameHandoff.finishActive()
        telemetry.recordRawFrameQueueDepth(depth)
      }
    }
  }

  private func consume(_ queuedFrame: HostQueuedCapturedFrame) {
    let frame = queuedFrame.frame
    let encoder: HostMediaActiveEncoder
    let generation: UInt64
    do {
      (encoder, generation) = try lock.withLock {
        guard active else { throw HostScreenCaptureError.streamStopped("cancelled") }
        if let existing = self.encoder {
          return (existing, encoderGeneration.current)
        }
        let pixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let generation = encoderGeneration.beginEncoder()
        let created = try self.makeEncoder(
          sourcePixelFormat: pixelFormat,
          generation: generation
        )
        self.encoder = created
        return (created, generation)
      }
      telemetry.record(
        .encodeSubmit,
        presentationTimeUS: queuedFrame.presentationTimeUS,
        byteCount: 0
      )
      do {
        try encoder.encode(
          frame: frame,
          presentationTime: queuedFrame.presentationTime
        )
      } catch {
        telemetry.record(
          .encodeRejected,
          presentationTimeUS: queuedFrame.presentationTimeUS,
          byteCount: 0
        )
        let reason = lock.withLock { () -> HostMediaDropReason in
          guard active else { return .shutdown }
          guard encoderGeneration.accepts(generation) else { return .reconfigure }
          return Self.dropReason(for: error)
        }
        telemetry.recordDrop(reason)
        emit(error: error, generation: generation)
      }
    } catch {
      let reason = lock.withLock {
        active ? Self.dropReason(for: error) : .shutdown
      }
      telemetry.recordDrop(reason)
      if reason != .shutdown { onError(error) }
    }
  }

  private func makeEncoder(
    sourcePixelFormat: OSType,
    generation: UInt64
  ) throws -> HostMediaActiveEncoder {
    switch configuration.codec {
    case .h264:
      return .h264(
        try HostH264Encoder(
          configuration: HostH264EncoderConfiguration(
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            framesPerSecond: Int32(configuration.framesPerSecond),
            averageBitRate: configuration.bitRate
          ),
          sourcePixelFormat: sourcePixelFormat,
          onAccessUnit: { [weak self] accessUnit in
            self?.emit(
              generation: generation,
              codec: .h264,
              data: accessUnit.data,
              presentationTimeUS: accessUnit.presentationTimeUS,
              isKeyframe: accessUnit.isKeyframe,
              hasParameterSets: accessUnit.hasParameterSets,
              logicalRawFrameCopyCount: accessUnit.logicalRawFrameCopyCount
            )
          },
          onState: { [weak self] state in
            self?.emit(state: state, generation: generation)
          },
          onDrop: { [weak self] presentationTimeUS, reason in
            self?.emit(
              drop: reason,
              presentationTimeUS: presentationTimeUS,
              generation: generation
            )
          },
          onError: { [weak self] error in
            self?.emit(error: error, generation: generation)
          }
        ))
    case .h265:
      return .h265(
        try HostHEVCEncoder(
          configuration: HostHEVCEncoderConfiguration(
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            framesPerSecond: Int32(configuration.framesPerSecond),
            averageBitRate: configuration.bitRate
          ),
          sourcePixelFormat: sourcePixelFormat,
          onAccessUnit: { [weak self] accessUnit in
            self?.emit(
              generation: generation,
              codec: .h265,
              data: accessUnit.data,
              presentationTimeUS: accessUnit.presentationTimeUS,
              isKeyframe: accessUnit.isKeyframe,
              hasParameterSets: accessUnit.hasParameterSets,
              logicalRawFrameCopyCount: accessUnit.logicalRawFrameCopyCount
            )
          },
          onState: { [weak self] state in
            self?.emit(state: state, generation: generation)
          },
          onDrop: { [weak self] presentationTimeUS, reason in
            self?.emit(
              drop: reason,
              presentationTimeUS: presentationTimeUS,
              generation: generation
            )
          },
          onError: { [weak self] error in
            self?.emit(error: error, generation: generation)
          }
        ))
    }
  }

  private func emit(
    generation: UInt64,
    codec: HostPipelineCodec,
    data: Data,
    presentationTimeUS: UInt64,
    isKeyframe: Bool,
    hasParameterSets: Bool,
    logicalRawFrameCopyCount: Int
  ) {
    telemetry.recordPacket(
      presentationTimeUS: presentationTimeUS,
      byteCount: data.count,
      isKeyframe: isKeyframe
    )
    telemetry.record(
      .packetReady,
      presentationTimeUS: presentationTimeUS,
      byteCount: data.count
    )
    let dropReason = lock.withLock { () -> HostMediaDropReason? in
      guard active else { return .shutdown }
      guard encoderGeneration.accepts(generation) else { return .reconfigure }
      return nil
    }
    if let dropReason {
      telemetry.recordDrop(dropReason)
      return
    }
    onAccessUnit(
      HostMediaAccessUnit(
        codec: codec,
        data: data,
        presentationTimeUS: presentationTimeUS,
        isKeyframe: isKeyframe,
        hasParameterSets: hasParameterSets,
        logicalRawFrameCopyCount: logicalRawFrameCopyCount
      ))
  }

  private func emit(state: HostEncoderRuntimeState, generation: UInt64) {
    guard lock.withLock({ active && encoderGeneration.accepts(generation) }) else {
      return
    }
    telemetry.recordEncoderState(state)
    onState(state)
  }

  private func emit(
    drop reason: HostMediaDropReason,
    presentationTimeUS: UInt64,
    generation: UInt64
  ) {
    let effectiveReason = lock.withLock { () -> HostMediaDropReason in
      guard active else { return .shutdown }
      guard encoderGeneration.accepts(generation) else { return .reconfigure }
      return reason
    }
    telemetry.recordEncoderDrop(
      presentationTimeUS: presentationTimeUS,
      reason: effectiveReason
    )
  }

  private func emit(error: Error, generation: UInt64) {
    guard lock.withLock({ active && encoderGeneration.accepts(generation) }) else {
      return
    }
    if Self.dropReason(for: error) == .encoderBackpressure { return }
    onError(error)
  }

  private static func dropReason(for error: Error) -> HostMediaDropReason {
    if case HostScreenCaptureError.streamStopped = error {
      return .shutdown
    }
    if case HostH264EncoderError.frameDropped = error {
      return .encoderBackpressure
    }
    if case HostHEVCEncoderError.frameDropped = error {
      return .encoderBackpressure
    }
    if case HostH264EncoderError.encode(let status) = error,
       status == kVTVideoEncoderNotAvailableNowErr {
      return .encoderBackpressure
    }
    if case HostH264EncoderError.callback(let status) = error,
       status == kVTVideoEncoderNotAvailableNowErr {
      return .encoderBackpressure
    }
    if case HostHEVCEncoderError.encode(let status) = error,
       status == kVTVideoEncoderNotAvailableNowErr {
      return .encoderBackpressure
    }
    if case HostHEVCEncoderError.callback(let status) = error,
       status == kVTVideoEncoderNotAvailableNowErr {
      return .encoderBackpressure
    }
    return .invalidFrame
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
