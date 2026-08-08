import Foundation

public struct HostMediaPipelineRouteIdentity: Equatable, Sendable {
  public let connectionEpoch: UInt64
  public let codecEpoch: UInt64
  public let displayID: UInt64
  public let displayRevision: UInt64
  public let codec: HostPipelineCodec

  public init(
    connectionEpoch: UInt64,
    codecEpoch: UInt64,
    displayID: UInt64,
    displayRevision: UInt64,
    codec: HostPipelineCodec
  ) {
    self.connectionEpoch = connectionEpoch
    self.codecEpoch = codecEpoch
    self.displayID = displayID
    self.displayRevision = displayRevision
    self.codec = codec
  }
}

public struct HostMediaPipelineRoute: Sendable {
  public let identity: HostMediaPipelineRouteIdentity
  public let configuration: HostMediaPipelineConfiguration

  public init(
    identity: HostMediaPipelineRouteIdentity,
    configuration: HostMediaPipelineConfiguration
  ) {
    self.identity = identity
    self.configuration = configuration
  }

  fileprivate var isValid: Bool {
    identity.connectionEpoch > 0
      && identity.codecEpoch > 0
      && identity.displayRevision > 0
      && identity.codec == configuration.codec
      && configuration.displayIndex >= 0
      && (16...16_384).contains(configuration.width)
      && (16...16_384).contains(configuration.height)
      && (1...240).contains(configuration.framesPerSecond)
      && (100_000...100_000_000).contains(configuration.bitRate)
  }
}

public enum HostMediaPipelineSubmissionDisposition: Sendable {
  case accepted
  case dropped(
    reason: HostMediaDropReason?,
    requiresKeyframeRecovery: Bool
  )
}

public enum HostMediaPipelineRouteFailure: Equatable, Sendable {
  case startFailed
  case runtimeFailed
}

/// Sanitized route lifecycle hooks. The observer receives only the typed route
/// identity and its in-memory telemetry; it never receives pipeline errors,
/// frame contents, encoded payloads, credentials, or server configuration.
public struct HostMediaPipelineRouteLifecycleObserver: Sendable {
  public typealias Handler = @Sendable (
    HostMediaPipelineRouteIdentity,
    HostMediaTelemetry
  ) -> Void

  public let onStarted: Handler
  public let onStartFailed: Handler
  public let onStopped: Handler

  public init(
    onStarted: @escaping Handler = { _, _ in },
    onStartFailed: @escaping Handler = { _, _ in },
    onStopped: @escaping Handler = { _, _ in }
  ) {
    self.onStarted = onStarted
    self.onStartFailed = onStartFailed
    self.onStopped = onStopped
  }
}

public struct HostMediaPipelineRouteCallbacks: Sendable {
  public let onAccessUnit: @Sendable (HostMediaAccessUnit) -> Void
  public let onState: @Sendable (HostEncoderRuntimeState) -> Void
  public let onError: @Sendable (Error) -> Void

  public init(
    onAccessUnit: @escaping @Sendable (HostMediaAccessUnit) -> Void,
    onState: @escaping @Sendable (HostEncoderRuntimeState) -> Void,
    onError: @escaping @Sendable (Error) -> Void
  ) {
    self.onAccessUnit = onAccessUnit
    self.onState = onState
    self.onError = onError
  }
}

public protocol HostMediaPipelineLifecycle: AnyObject {
  var telemetry: HostMediaTelemetry { get }
  func start() async throws
  func requestKeyframe()
  func recoverFromEncodedPacketDrop()
  func cancel()
  func stop() async
}

extension HostMediaPipeline: HostMediaPipelineLifecycle {}

public struct HostMediaPipelineRouteTelemetrySnapshot: Sendable {
  public let route: HostMediaPipelineRouteIdentity
  public let telemetry: HostMediaTelemetrySnapshot
}

public struct HostMediaPipelineRouteOwnerSnapshot: Sendable {
  public let desiredRoute: HostMediaPipelineRouteIdentity?
  public let activeRoute: HostMediaPipelineRouteIdentity?
  public let activeTelemetry: HostMediaPipelineRouteTelemetrySnapshot?
  public let lastCompletedTelemetry: HostMediaPipelineRouteTelemetrySnapshot?
  public let scheduledOperationCount: UInt64
  public let completedOperationCount: UInt64
  public let pendingOperationCount: Int
  public let rejectedTelemetryUpdateCount: UInt64
  public let cancelled: Bool
}

/// Owns one real SCK/VideoToolbox pipeline at a time. Lifecycle work is
/// serialized away from Core callbacks, while synchronous cancellation first
/// prevents new submissions and then waits for capture/encoder queues to drain.
public final class HostMediaPipelineRouteOwner: @unchecked Sendable {
  public typealias PipelineFactory = (
    HostMediaPipelineConfiguration,
    HostMediaTelemetry,
    HostMediaPipelineRouteCallbacks
  ) throws -> any HostMediaPipelineLifecycle
  public typealias SubmissionHandler = @Sendable (
    HostMediaPipelineRouteIdentity,
    HostMediaAccessUnit
  ) -> HostMediaPipelineSubmissionDisposition
  public typealias EncoderStateHandler = @Sendable (
    HostMediaPipelineRouteIdentity,
    HostEncoderRuntimeState
  ) -> Void
  public typealias FailureHandler = @Sendable (
    HostMediaPipelineRouteIdentity,
    HostMediaPipelineRouteFailure
  ) -> Void

  private struct CurrentPipeline {
    let generation: UInt64
    let route: HostMediaPipelineRouteIdentity
    let pipeline: any HostMediaPipelineLifecycle
    var active: Bool
  }

  private struct RetainedTelemetry {
    let generation: UInt64
    let route: HostMediaPipelineRouteIdentity
    let telemetry: HostMediaTelemetry
  }

  private let condition = NSCondition()
  private let operationQueue = DispatchQueue(
    label: "io.farpane.host-media-route-owner",
    qos: .userInitiated
  )
  private let pipelineFactory: PipelineFactory
  private let lifecycleObserver: HostMediaPipelineRouteLifecycleObserver
  private let onSubmit: SubmissionHandler
  private let onEncoderState: EncoderStateHandler
  private let onFailure: FailureHandler
  private var desiredRoute: HostMediaPipelineRouteIdentity?
  private var current: CurrentPipeline?
  private var retiringTelemetry: RetainedTelemetry?
  private var lastCompletedTelemetry: RetainedTelemetry?
  private var generation: UInt64 = 0
  private var scheduledOperationCount: UInt64 = 0
  private var completedOperationCount: UInt64 = 0
  private var pendingOperationCount = 0
  private var rejectedTelemetryUpdateCount: UInt64 = 0
  private var cancelled = false

  public init(
    pipelineFactory: @escaping PipelineFactory = { configuration, telemetry, callbacks in
      HostMediaPipeline(
        configuration: configuration,
        telemetry: telemetry,
        onAccessUnit: callbacks.onAccessUnit,
        onState: callbacks.onState,
        onError: callbacks.onError
      )
    },
    lifecycleObserver: HostMediaPipelineRouteLifecycleObserver = .init(),
    onSubmit: @escaping SubmissionHandler,
    onEncoderState: @escaping EncoderStateHandler,
    onFailure: @escaping FailureHandler
  ) {
    self.pipelineFactory = pipelineFactory
    self.lifecycleObserver = lifecycleObserver
    self.onSubmit = onSubmit
    self.onEncoderState = onEncoderState
    self.onFailure = onFailure
  }

  deinit {
    cancelAndWait()
  }

  @discardableResult
  public func reconfigure(_ route: HostMediaPipelineRoute) -> Bool {
    guard route.isValid else { return false }
    condition.lock()
    guard !cancelled, generation < UInt64.max else {
      condition.unlock()
      return false
    }
    generation += 1
    let operationGeneration = generation
    desiredRoute = route.identity
    scheduleOperationLocked()
    let startingPipeline = current?.active == false ? current?.pipeline : nil
    condition.unlock()

    // Interrupt a start that is currently awaiting ScreenCaptureKit.
    startingPipeline?.cancel()
    operationQueue.async { [self] in
      defer { finishOperation() }
      performReconfigure(route, generation: operationGeneration)
    }
    return true
  }

  @discardableResult
  public func requestKeyframe(route: HostMediaPipelineRouteIdentity) -> Bool {
    condition.lock()
    guard !cancelled,
          let current,
          current.active,
          current.route == route
    else {
      condition.unlock()
      return false
    }
    let pipeline = current.pipeline
    condition.unlock()
    pipeline.requestKeyframe()
    return true
  }

  @discardableResult
  public func stop(route: HostMediaPipelineRouteIdentity) -> Bool {
    condition.lock()
    guard !cancelled,
          desiredRoute == route || current?.route == route,
          generation < UInt64.max
    else {
      condition.unlock()
      return false
    }
    let stopsDesiredRoute = desiredRoute == route
    generation += 1
    if stopsDesiredRoute { desiredRoute = nil }
    scheduleOperationLocked()
    let startingPipeline = current?.route == route && current?.active == false
      ? current?.pipeline
      : nil
    condition.unlock()

    startingPipeline?.cancel()
    operationQueue.async { [self] in
      defer { finishOperation() }
      stopCurrentOnQueue(matching: stopsDesiredRoute ? nil : route)
    }
    return true
  }

  /// Terminal and idempotent. Must not be called from the operation queue or
  /// from a pipeline callback currently being drained by `stop()`.
  public func cancelAndWait() {
    condition.lock()
    if !cancelled {
      cancelled = true
      desiredRoute = nil
      if generation < UInt64.max { generation += 1 }
    }
    let pipeline = current?.pipeline
    condition.unlock()

    pipeline?.cancel()
    operationQueue.sync { [self] in
      stopCurrentOnQueue(matching: nil)
    }
  }

  public func snapshot() -> HostMediaPipelineRouteOwnerSnapshot {
    condition.lock()
    let desiredRoute = desiredRoute
    let active = current?.active == true ? current : nil
    let completed = lastCompletedTelemetry
    let scheduledOperationCount = scheduledOperationCount
    let completedOperationCount = completedOperationCount
    let pendingOperationCount = pendingOperationCount
    let rejectedTelemetryUpdateCount = rejectedTelemetryUpdateCount
    let cancelled = cancelled
    condition.unlock()
    return HostMediaPipelineRouteOwnerSnapshot(
      desiredRoute: desiredRoute,
      activeRoute: active?.route,
      activeTelemetry: active.map {
        HostMediaPipelineRouteTelemetrySnapshot(
          route: $0.route,
          telemetry: $0.pipeline.telemetry.snapshot()
        )
      },
      lastCompletedTelemetry: completed.map {
        HostMediaPipelineRouteTelemetrySnapshot(
          route: $0.route,
          telemetry: $0.telemetry.snapshot()
        )
      },
      scheduledOperationCount: scheduledOperationCount,
      completedOperationCount: completedOperationCount,
      pendingOperationCount: pendingOperationCount,
      rejectedTelemetryUpdateCount: rejectedTelemetryUpdateCount,
      cancelled: cancelled
    )
  }

  /// Cheap route lookup for control/diagnostic admission. Unlike `snapshot()`,
  /// this does not sample or sort telemetry on the event callback queue.
  public func routeIdentities(
    includingRetainedTelemetry: Bool = false
  ) -> [HostMediaPipelineRouteIdentity] {
    condition.lock()
    var routes = [current?.route, desiredRoute].compactMap { $0 }
    if includingRetainedTelemetry {
      routes.append(contentsOf: [
        retiringTelemetry?.route,
        lastCompletedTelemetry?.route,
      ].compactMap { $0 })
    }
    condition.unlock()
    var unique: [HostMediaPipelineRouteIdentity] = []
    for route in routes where !unique.contains(route) {
      unique.append(route)
    }
    return unique
  }

  @discardableResult
  public func recordEncodedQueueDepth(
    route: HostMediaPipelineRouteIdentity,
    current: Int,
    maximum: Int,
    capacity: Int,
    finalized: Bool
  ) -> Bool {
    updateTelemetry(route: route) {
      $0.recordEncodedQueueDepth(
        current: current,
        maximum: maximum,
        capacity: capacity,
        finalized: finalized
      )
    }
  }

  @discardableResult
  public func recordWriterTiming(
    route: HostMediaPipelineRouteIdentity,
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
    updateTelemetry(route: route) {
      $0.recordWriterTiming(
        cycles: cycles,
        subscriberDispatches: subscriberDispatches,
        dispatchWallTotalUS: dispatchWallTotalUS,
        maximumDispatchWallUS: maximumDispatchWallUS,
        confirmationWaitTotalUS: confirmationWaitTotalUS,
        maximumConfirmationWaitUS: maximumConfirmationWaitUS,
        completedConfirmations: completedConfirmations,
        timedOutConfirmations: timedOutConfirmations,
        finalized: finalized
      )
    }
  }

  @discardableResult
  public func recordNetworkMetrics(
    route: HostMediaPipelineRouteIdentity,
    subscriberCount: Int,
    qosSubscriberCount: Int,
    delaySampledSubscribers: Int,
    rttSampledSubscribers: Int,
    responseDelayedSubscribers: Int,
    networkDelayMS: Int?,
    roundTripTimeMS: Int?,
    finalized: Bool
  ) -> Bool {
    updateTelemetry(route: route) {
      $0.recordNetworkMetrics(
        subscriberCount: subscriberCount,
        qosSubscriberCount: qosSubscriberCount,
        delaySampledSubscribers: delaySampledSubscribers,
        rttSampledSubscribers: rttSampledSubscribers,
        responseDelayedSubscribers: responseDelayedSubscribers,
        networkDelayMS: networkDelayMS,
        roundTripTimeMS: roundTripTimeMS,
        finalized: finalized
      )
    }
  }

  @discardableResult
  public func recordTransportMetrics(
    route: HostMediaPipelineRouteIdentity,
    subscriberCount: Int,
    directSubscribers: Int,
    relaySubscribers: Int,
    unknownSubscribers: Int,
    finalized: Bool
  ) -> Bool {
    updateTelemetry(route: route) {
      $0.recordTransportMetrics(
        subscriberCount: subscriberCount,
        directSubscribers: directSubscribers,
        relaySubscribers: relaySubscribers,
        unknownSubscribers: unknownSubscribers,
        finalized: finalized
      )
    }
  }

  package func waitUntilIdle() {
    operationQueue.sync {}
  }

  private func performReconfigure(
    _ route: HostMediaPipelineRoute,
    generation operationGeneration: UInt64
  ) {
    guard shouldRun(generation: operationGeneration, route: route.identity) else {
      return
    }
    stopCurrentOnQueue(matching: nil)
    guard shouldRun(generation: operationGeneration, route: route.identity) else {
      return
    }

    let telemetry = HostMediaTelemetry(configuration: route.configuration)
    telemetry.markDropReasonsInstrumented([.networkBackpressure])
    let callbacks = HostMediaPipelineRouteCallbacks(
      onAccessUnit: { [weak self] unit in
        self?.handleAccessUnit(
          unit,
          route: route.identity,
          generation: operationGeneration,
          telemetry: telemetry
        )
      },
      onState: { [weak self] state in
        self?.handleEncoderState(
          state,
          route: route.identity,
          generation: operationGeneration
        )
      },
      onError: { [weak self] _ in
        self?.handleRuntimeFailure(
          route: route.identity,
          generation: operationGeneration
        )
      }
    )

    let pipeline: any HostMediaPipelineLifecycle
    do {
      pipeline = try pipelineFactory(route.configuration, telemetry, callbacks)
    } catch {
      clearDesiredRouteIfCurrent(route.identity, generation: operationGeneration)
      lifecycleObserver.onStartFailed(route.identity, telemetry)
      onFailure(route.identity, .startFailed)
      return
    }

    condition.lock()
    guard !cancelled,
          generation == operationGeneration,
          desiredRoute == route.identity
    else {
      condition.unlock()
      pipeline.cancel()
      blockingStop(pipeline)
      return
    }
    current = CurrentPipeline(
      generation: operationGeneration,
      route: route.identity,
      pipeline: pipeline,
      active: false
    )
    condition.unlock()

    let startResult = blockingStart(pipeline)
    condition.lock()
    let stillCurrent = !cancelled
      && generation == operationGeneration
      && desiredRoute == route.identity
      && current?.generation == operationGeneration
    if stillCurrent, startResult.isSuccess {
      current?.active = true
      condition.unlock()
      lifecycleObserver.onStarted(route.identity, pipeline.telemetry)
      return
    }
    if current?.generation == operationGeneration { current = nil }
    if desiredRoute == route.identity { desiredRoute = nil }
    retiringTelemetry = RetainedTelemetry(
      generation: operationGeneration,
      route: route.identity,
      telemetry: pipeline.telemetry
    )
    condition.unlock()

    pipeline.cancel()
    blockingStop(pipeline)
    finishRetiringTelemetry(generation: operationGeneration)
    if startResult.isFailure {
      lifecycleObserver.onStartFailed(route.identity, pipeline.telemetry)
      onFailure(route.identity, .startFailed)
    }
  }

  private func handleAccessUnit(
    _ unit: HostMediaAccessUnit,
    route: HostMediaPipelineRouteIdentity,
    generation callbackGeneration: UInt64,
    telemetry: HostMediaTelemetry
  ) {
    condition.lock()
    let acceptedGeneration = !cancelled
      && current?.generation == callbackGeneration
      && current?.route == route
    condition.unlock()
    guard acceptedGeneration else {
      telemetry.recordDrop(.reconfigure)
      return
    }
    guard unit.codec == route.codec, !unit.data.isEmpty else {
      telemetry.recordDrop(.invalidFrame)
      return
    }

    telemetry.record(
      .sendSubmit,
      presentationTimeUS: unit.presentationTimeUS,
      byteCount: unit.data.count
    )
    switch onSubmit(route, unit) {
    case .accepted:
      telemetry.record(
        .sendAccepted,
        presentationTimeUS: unit.presentationTimeUS,
        byteCount: unit.data.count
      )
    case .dropped(let reason, let requiresKeyframeRecovery):
      telemetry.record(
        .sendDropped,
        presentationTimeUS: unit.presentationTimeUS,
        byteCount: unit.data.count
      )
      if let reason {
        telemetry.recordDrop(reason)
      } else {
        telemetry.recordUnclassifiedDrop()
      }
      if requiresKeyframeRecovery {
        recoverCurrentPipeline(route: route, generation: callbackGeneration)
      }
    }
  }

  private func handleEncoderState(
    _ state: HostEncoderRuntimeState,
    route: HostMediaPipelineRouteIdentity,
    generation callbackGeneration: UInt64
  ) {
    condition.lock()
    let acceptedGeneration = !cancelled
      && current?.generation == callbackGeneration
      && current?.route == route
    condition.unlock()
    if acceptedGeneration { onEncoderState(route, state) }
  }

  private func handleRuntimeFailure(
    route: HostMediaPipelineRouteIdentity,
    generation callbackGeneration: UInt64
  ) {
    condition.lock()
    let acceptedGeneration = !cancelled
      && current?.generation == callbackGeneration
      && current?.route == route
    condition.unlock()
    guard acceptedGeneration else { return }
    onFailure(route, .runtimeFailed)
    _ = stop(route: route)
  }

  private func recoverCurrentPipeline(
    route: HostMediaPipelineRouteIdentity,
    generation callbackGeneration: UInt64
  ) {
    condition.lock()
    let pipeline = !cancelled
      && current?.generation == callbackGeneration
      && current?.route == route
      ? current?.pipeline
      : nil
    condition.unlock()
    pipeline?.recoverFromEncodedPacketDrop()
  }

  private func shouldRun(
    generation operationGeneration: UInt64,
    route: HostMediaPipelineRouteIdentity
  ) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    return !cancelled
      && generation == operationGeneration
      && desiredRoute == route
  }

  private func stopCurrentOnQueue(
    matching route: HostMediaPipelineRouteIdentity?
  ) {
    condition.lock()
    guard let current,
          route == nil || current.route == route
    else {
      condition.unlock()
      return
    }
    self.current = nil
    retiringTelemetry = RetainedTelemetry(
      generation: current.generation,
      route: current.route,
      telemetry: current.pipeline.telemetry
    )
    condition.unlock()
    current.pipeline.cancel()
    blockingStop(current.pipeline)
    finishRetiringTelemetry(generation: current.generation)
    if current.active {
      lifecycleObserver.onStopped(current.route, current.pipeline.telemetry)
    }
  }

  private func updateTelemetry(
    route: HostMediaPipelineRouteIdentity,
    _ update: (HostMediaTelemetry) -> Bool
  ) -> Bool {
    condition.lock()
    let telemetry: HostMediaTelemetry?
    if current?.route == route {
      telemetry = current?.pipeline.telemetry
    } else if retiringTelemetry?.route == route {
      telemetry = retiringTelemetry?.telemetry
    } else if lastCompletedTelemetry?.route == route {
      telemetry = lastCompletedTelemetry?.telemetry
    } else {
      telemetry = nil
    }
    condition.unlock()
    guard let telemetry else {
      recordTelemetryUpdateRejection()
      return false
    }
    let accepted = update(telemetry)
    if !accepted { recordTelemetryUpdateRejection() }
    return accepted
  }

  private func finishRetiringTelemetry(generation: UInt64) {
    condition.lock()
    if retiringTelemetry?.generation == generation {
      lastCompletedTelemetry = retiringTelemetry
      retiringTelemetry = nil
    }
    condition.unlock()
  }

  private func recordTelemetryUpdateRejection() {
    condition.lock()
    if rejectedTelemetryUpdateCount < UInt64.max {
      rejectedTelemetryUpdateCount += 1
    }
    condition.unlock()
  }

  private func clearDesiredRouteIfCurrent(
    _ route: HostMediaPipelineRouteIdentity,
    generation operationGeneration: UInt64
  ) {
    condition.lock()
    if generation == operationGeneration, desiredRoute == route {
      desiredRoute = nil
    }
    condition.unlock()
  }

  private func scheduleOperationLocked() {
    pendingOperationCount += 1
    if scheduledOperationCount < UInt64.max { scheduledOperationCount += 1 }
  }

  private func finishOperation() {
    condition.lock()
    pendingOperationCount -= 1
    if completedOperationCount < UInt64.max { completedOperationCount += 1 }
    condition.broadcast()
    condition.unlock()
  }

  private func blockingStart(
    _ pipeline: any HostMediaPipelineLifecycle
  ) -> Result<Void, Error> {
    let box = HostMediaAsyncResultBox<Result<Void, Error>>()
    Task {
      do {
        try await pipeline.start()
        box.complete(.success(()))
      } catch {
        box.complete(.failure(error))
      }
    }
    return box.wait()
  }

  private func blockingStop(_ pipeline: any HostMediaPipelineLifecycle) {
    let box = HostMediaAsyncResultBox<Void>()
    Task {
      await pipeline.stop()
      box.complete(())
    }
    box.wait()
  }
}

private final class HostMediaAsyncResultBox<Value>: @unchecked Sendable {
  private let condition = NSCondition()
  private var value: Value?

  func complete(_ value: Value) {
    condition.lock()
    self.value = value
    condition.broadcast()
    condition.unlock()
  }

  func wait() -> Value {
    condition.lock()
    defer { condition.unlock() }
    while value == nil { condition.wait() }
    return value!
  }
}

private extension Result {
  var isSuccess: Bool {
    if case .success = self { return true }
    return false
  }

  var isFailure: Bool { !isSuccess }
}
