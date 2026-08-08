@testable import VideoPipeline
import Foundation
import XCTest

final class HostMediaPipelineRouteOwnerTests: XCTestCase {
  func testStartsSubmitsReportsRequestsIDRAndStopsOneRoute() {
    let factory = RecordingRoutePipelineFactory()
    let recorder = RouteOwnerRecorder()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { route, unit in
        recorder.recordSubmission(route: route, unit: unit)
        return .accepted
      },
      onEncoderState: { route, state in
        recorder.recordState(route: route, state: state)
      },
      onFailure: { route, failure in
        recorder.recordFailure(route: route, failure: failure)
      }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)

    XCTAssertTrue(owner.reconfigure(route))
    owner.waitUntilIdle()
    let pipeline = try! XCTUnwrap(factory.pipelines.first)
    XCTAssertEqual(pipeline.operations, [.start])
    pipeline.emitAccessUnit()
    pipeline.emitState()

    XCTAssertEqual(recorder.submissions.count, 1)
    XCTAssertEqual(recorder.submissions.first?.0, route.identity)
    XCTAssertEqual(recorder.states.count, 1)
    XCTAssertEqual(recorder.states.first?.0, route.identity)
    XCTAssertTrue(owner.requestKeyframe(route: route.identity))
    XCTAssertEqual(pipeline.operations, [.start, .requestKeyframe])
    XCTAssertTrue(owner.stop(route: route.identity))
    owner.waitUntilIdle()
    XCTAssertEqual(pipeline.operations, [
      .start,
      .requestKeyframe,
      .cancel,
      .stop,
    ])
    XCTAssertNil(owner.snapshot().activeRoute)
    XCTAssertEqual(owner.snapshot().scheduledOperationCount, 2)
    XCTAssertEqual(owner.snapshot().completedOperationCount, 2)
    XCTAssertTrue(recorder.failures.isEmpty)
  }

  func testReplacementStopsOldPipelineAndRejectsItsLateCallbacks() {
    let factory = RecordingRoutePipelineFactory()
    let recorder = RouteOwnerRecorder()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { route, unit in
        recorder.recordSubmission(route: route, unit: unit)
        return .accepted
      },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let first = makeRoute(connectionEpoch: 11, codecEpoch: 21)
    let second = makeRoute(connectionEpoch: 12, codecEpoch: 22, codec: .h265)

    XCTAssertTrue(owner.reconfigure(first))
    owner.waitUntilIdle()
    let firstPipeline = try! XCTUnwrap(factory.pipelines.first)
    XCTAssertTrue(owner.reconfigure(second))
    owner.waitUntilIdle()
    let secondPipeline = try! XCTUnwrap(factory.pipelines.last)

    XCTAssertEqual(firstPipeline.operations, [.start, .cancel, .stop])
    XCTAssertEqual(secondPipeline.operations, [.start])
    firstPipeline.emitAccessUnit()
    secondPipeline.emitAccessUnit(codec: .h265)
    XCTAssertEqual(recorder.submissions.map(\.0), [second.identity])
    XCTAssertEqual(firstPipeline.telemetry.snapshot().drops.reconfigure, 1)
    XCTAssertEqual(owner.snapshot().activeRoute, second.identity)
  }

  func testLifecycleObserverPublishesStartedAndStoppedRoutesInDrainOrder() {
    let factory = RecordingRoutePipelineFactory()
    let recorder = RouteOwnerRecorder()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      lifecycleObserver: HostMediaPipelineRouteLifecycleObserver(
        onStarted: { route, telemetry in
          recorder.recordLifecycle(
            .started(route),
            requestedFPS: telemetry.snapshot().requestedFPS
          )
        },
        onStartFailed: { route, telemetry in
          recorder.recordLifecycle(
            .startFailed(route),
            requestedFPS: telemetry.snapshot().requestedFPS
          )
        },
        onStopped: { route, telemetry in
          recorder.recordLifecycle(
            .stopped(route),
            requestedFPS: telemetry.snapshot().requestedFPS
          )
        }
      ),
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let first = makeRoute(connectionEpoch: 11, codecEpoch: 21)
    let second = makeRoute(connectionEpoch: 12, codecEpoch: 22, codec: .h265)

    XCTAssertTrue(owner.reconfigure(first))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.reconfigure(second))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.stop(route: second.identity))
    owner.waitUntilIdle()

    XCTAssertEqual(recorder.lifecycleEvents, [
      .started(first.identity),
      .stopped(first.identity),
      .started(second.identity),
      .stopped(second.identity),
    ])
    XCTAssertEqual(recorder.lifecycleRequestedFPS, [30, 30, 30, 30])
  }

  func testBackpressureRecoveryTargetsOnlyCurrentGeneration() {
    let factory = RecordingRoutePipelineFactory()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { _, _ in
        .dropped(reason: .networkBackpressure, requiresKeyframeRecovery: true)
      },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)

    XCTAssertTrue(owner.reconfigure(route))
    owner.waitUntilIdle()
    let pipeline = try! XCTUnwrap(factory.pipelines.first)
    pipeline.emitAccessUnit()

    XCTAssertEqual(pipeline.operations, [.start, .recover])
    let telemetry = pipeline.telemetry.snapshot()
    XCTAssertEqual(telemetry.sendSubmissions, 1)
    XCTAssertEqual(telemetry.sendDropped, 1)
    XCTAssertEqual(telemetry.drops.networkBackpressure, 1)
  }

  func testStartFailureStopsPipelineAndPublishesSanitizedFailure() {
    let factory = RecordingRoutePipelineFactory(startFailure: true)
    let recorder = RouteOwnerRecorder()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      lifecycleObserver: HostMediaPipelineRouteLifecycleObserver(
        onStartFailed: { route, telemetry in
          recorder.recordLifecycle(
            .startFailed(route),
            requestedFPS: telemetry.snapshot().requestedFPS
          )
        }
      ),
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { route, failure in
        recorder.recordFailure(route: route, failure: failure)
      }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)

    XCTAssertTrue(owner.reconfigure(route))
    owner.waitUntilIdle()

    let pipeline = try! XCTUnwrap(factory.pipelines.first)
    XCTAssertEqual(pipeline.operations, [.start, .cancel, .stop])
    XCTAssertEqual(recorder.failures.count, 1)
    XCTAssertEqual(recorder.failures.first?.0, route.identity)
    XCTAssertEqual(recorder.failures.first?.1, .startFailed)
    XCTAssertEqual(recorder.lifecycleEvents, [.startFailed(route.identity)])
    XCTAssertEqual(recorder.lifecycleRequestedFPS, [30])
    XCTAssertNil(owner.snapshot().activeRoute)
  }

  func testFactoryFailurePublishesLifecycleFailureWithoutCreatingPipeline() {
    let recorder = RouteOwnerRecorder()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: { _, _, _ in
        throw RoutePipelineTestFailure.start
      },
      lifecycleObserver: HostMediaPipelineRouteLifecycleObserver(
        onStartFailed: { route, telemetry in
          recorder.recordLifecycle(
            .startFailed(route),
            requestedFPS: telemetry.snapshot().requestedFPS
          )
        }
      ),
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { route, failure in
        recorder.recordFailure(route: route, failure: failure)
      }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)

    XCTAssertTrue(owner.reconfigure(route))
    owner.waitUntilIdle()

    XCTAssertEqual(recorder.failures.first?.1, .startFailed)
    XCTAssertEqual(recorder.lifecycleEvents, [.startFailed(route.identity)])
    XCTAssertEqual(recorder.lifecycleRequestedFPS, [30])
    XCTAssertNil(owner.snapshot().desiredRoute)
    XCTAssertNil(owner.snapshot().activeRoute)
  }

  func testRejectsInvalidRouteAndMismatchedAccessUnitBeforeSubmission() {
    let factory = RecordingRoutePipelineFactory()
    let recorder = RouteOwnerRecorder()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { route, unit in
        recorder.recordSubmission(route: route, unit: unit)
        return .accepted
      },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let valid = makeRoute(connectionEpoch: 11, codecEpoch: 21)
    let invalid = HostMediaPipelineRoute(
      identity: valid.identity,
      configuration: HostMediaPipelineConfiguration(
        codec: .h265,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      )
    )

    XCTAssertFalse(owner.reconfigure(invalid))
    XCTAssertTrue(factory.pipelines.isEmpty)
    XCTAssertTrue(owner.reconfigure(valid))
    owner.waitUntilIdle()
    let pipeline = try! XCTUnwrap(factory.pipelines.first)
    pipeline.emitAccessUnit(codec: .h265)
    XCTAssertTrue(recorder.submissions.isEmpty)
    XCTAssertEqual(pipeline.telemetry.snapshot().drops.invalidFrame, 1)
  }

  func testCancelWaitsForStartingPipelineAndRejectsNewWork() {
    let startGate = RoutePipelineAsyncStartGate()
    let factory = RecordingRoutePipelineFactory(startGate: startGate)
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)
    let cancelReturned = DispatchSemaphore(value: 0)

    XCTAssertTrue(owner.reconfigure(route))
    XCTAssertEqual(startGate.entered.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async {
      owner.cancelAndWait()
      cancelReturned.signal()
    }
    XCTAssertEqual(cancelReturned.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertFalse(owner.reconfigure(makeRoute(connectionEpoch: 12, codecEpoch: 22)))
    startGate.release()
    XCTAssertEqual(cancelReturned.wait(timeout: .now() + 2), .success)

    let pipeline = try! XCTUnwrap(factory.pipelines.first)
    XCTAssertTrue(pipeline.operations.contains(.cancel))
    XCTAssertTrue(pipeline.operations.contains(.stop))
    XCTAssertTrue(owner.snapshot().cancelled)
    XCTAssertNil(owner.snapshot().activeRoute)
    owner.cancelAndWait()
  }

  func testRecordsRustDiagnosticsForActiveAndJustCompletedRoute() {
    let factory = RecordingRoutePipelineFactory()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)

    XCTAssertTrue(owner.reconfigure(route))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.recordEncodedQueueDepth(
      route: route.identity,
      current: 2,
      maximum: 3,
      capacity: 4,
      finalized: false
    ))
    XCTAssertTrue(owner.recordWriterTiming(
      route: route.identity,
      cycles: 2,
      subscriberDispatches: 3,
      dispatchWallTotalUS: 100,
      maximumDispatchWallUS: 60,
      confirmationWaitTotalUS: 500,
      maximumConfirmationWaitUS: 300,
      completedConfirmations: 2,
      timedOutConfirmations: 0,
      finalized: false
    ))
    XCTAssertTrue(owner.recordNetworkMetrics(
      route: route.identity,
      subscriberCount: 1,
      qosSubscriberCount: 1,
      delaySampledSubscribers: 1,
      rttSampledSubscribers: 1,
      responseDelayedSubscribers: 0,
      networkDelayMS: 20,
      roundTripTimeMS: 30,
      finalized: false
    ))
    XCTAssertTrue(owner.recordTransportMetrics(
      route: route.identity,
      subscriberCount: 1,
      directSubscribers: 0,
      relaySubscribers: 1,
      unknownSubscribers: 0,
      finalized: false
    ))

    let active = try! XCTUnwrap(owner.snapshot().activeTelemetry)
    XCTAssertEqual(active.route, route.identity)
    XCTAssertEqual(active.telemetry.encodedQueueDepth, 2)
    XCTAssertEqual(active.telemetry.writerCycles, 2)
    XCTAssertEqual(active.telemetry.networkDelayMS, 20)
    XCTAssertEqual(active.telemetry.relaySubscribers, 1)

    XCTAssertTrue(owner.stop(route: route.identity))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.recordEncodedQueueDepth(
      route: route.identity,
      current: 0,
      maximum: 3,
      capacity: 4,
      finalized: true
    ))
    let completed = try! XCTUnwrap(owner.snapshot().lastCompletedTelemetry)
    XCTAssertEqual(completed.route, route.identity)
    XCTAssertEqual(completed.telemetry.encodedQueueDepth, 0)
    XCTAssertTrue(completed.telemetry.encodedQueueFinalized)
    XCTAssertNil(owner.snapshot().activeTelemetry)
  }

  func testKeepsDiagnosticsRouteScopedAndBoundsCompletedHistory() {
    let factory = RecordingRoutePipelineFactory()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let first = makeRoute(connectionEpoch: 11, codecEpoch: 21)
    let second = makeRoute(connectionEpoch: 12, codecEpoch: 22, codec: .h265)
    let stale = makeRoute(connectionEpoch: 10, codecEpoch: 20)

    XCTAssertTrue(owner.reconfigure(first))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.reconfigure(second))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.recordEncodedQueueDepth(
      route: first.identity,
      current: 1,
      maximum: 1,
      capacity: 3,
      finalized: true
    ))
    XCTAssertFalse(owner.recordEncodedQueueDepth(
      route: stale.identity,
      current: 1,
      maximum: 1,
      capacity: 3,
      finalized: false
    ))

    let snapshot = owner.snapshot()
    XCTAssertEqual(snapshot.activeTelemetry?.route, second.identity)
    XCTAssertNil(snapshot.activeTelemetry?.telemetry.encodedQueueDepth)
    XCTAssertEqual(snapshot.lastCompletedTelemetry?.route, first.identity)
    XCTAssertEqual(snapshot.lastCompletedTelemetry?.telemetry.encodedQueueDepth, 1)
    XCTAssertEqual(snapshot.rejectedTelemetryUpdateCount, 1)
    XCTAssertEqual(snapshot.pendingOperationCount, 0)
    XCTAssertEqual(owner.routeIdentities(), [second.identity])
    let retained = owner.routeIdentities(includingRetainedTelemetry: true)
    XCTAssertEqual(retained.count, 2)
    XCTAssertTrue(retained.contains(first.identity))
    XCTAssertTrue(retained.contains(second.identity))
  }

  func testStoppingQueuedReplacementAlsoStopsSupersededActiveRoute() {
    let factory = RecordingRoutePipelineFactory()
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let first = makeRoute(connectionEpoch: 11, codecEpoch: 21)
    let replacement = makeRoute(connectionEpoch: 12, codecEpoch: 22, codec: .h265)

    XCTAssertTrue(owner.reconfigure(first))
    owner.waitUntilIdle()
    let firstPipeline = try! XCTUnwrap(factory.pipelines.first)
    XCTAssertTrue(owner.reconfigure(replacement))
    XCTAssertTrue(owner.stop(route: replacement.identity))
    owner.waitUntilIdle()

    XCTAssertNil(owner.snapshot().activeRoute)
    XCTAssertNil(owner.snapshot().desiredRoute)
    XCTAssertEqual(firstPipeline.operations, [.start, .cancel, .stop])
    XCTAssertEqual(factory.pipelines.count, 1)
  }

  func testAcceptsFinalDiagnosticWhilePipelineStopIsDraining() {
    let stopGate = RoutePipelineAsyncStartGate()
    let factory = RecordingRoutePipelineFactory(stopGate: stopGate)
    let owner = HostMediaPipelineRouteOwner(
      pipelineFactory: factory.make,
      onSubmit: { _, _ in .accepted },
      onEncoderState: { _, _ in },
      onFailure: { _, _ in }
    )
    let route = makeRoute(connectionEpoch: 11, codecEpoch: 21)

    XCTAssertTrue(owner.reconfigure(route))
    owner.waitUntilIdle()
    XCTAssertTrue(owner.stop(route: route.identity))
    XCTAssertEqual(stopGate.entered.wait(timeout: .now() + 2), .success)
    XCTAssertTrue(owner.recordEncodedQueueDepth(
      route: route.identity,
      current: 0,
      maximum: 2,
      capacity: 3,
      finalized: true
    ))
    stopGate.release()
    owner.waitUntilIdle()

    XCTAssertEqual(
      owner.snapshot().lastCompletedTelemetry?.telemetry.encodedQueueDepth,
      0
    )
    XCTAssertTrue(
      owner.snapshot().lastCompletedTelemetry?.telemetry.encodedQueueFinalized == true
    )
  }

  private func makeRoute(
    connectionEpoch: UInt64,
    codecEpoch: UInt64,
    codec: HostPipelineCodec = .h264
  ) -> HostMediaPipelineRoute {
    HostMediaPipelineRoute(
      identity: HostMediaPipelineRouteIdentity(
        connectionEpoch: connectionEpoch,
        codecEpoch: codecEpoch,
        displayID: 0,
        displayRevision: 3,
        codec: codec
      ),
      configuration: HostMediaPipelineConfiguration(
        codec: codec,
        displayIndex: 0,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30,
        bitRate: 4_000_000
      )
    )
  }
}

private enum RoutePipelineTestFailure: Error {
  case start
}

private enum RoutePipelineOperation: Equatable {
  case start
  case requestKeyframe
  case recover
  case cancel
  case stop
}

private final class RecordingRoutePipeline: HostMediaPipelineLifecycle, @unchecked Sendable {
  let telemetry: HostMediaTelemetry
  private let callbacks: HostMediaPipelineRouteCallbacks
  private let startFailure: Bool
  private let startGate: RoutePipelineAsyncStartGate?
  private let stopGate: RoutePipelineAsyncStartGate?
  private let lock = NSLock()
  private var recordedOperations: [RoutePipelineOperation] = []

  init(
    telemetry: HostMediaTelemetry,
    callbacks: HostMediaPipelineRouteCallbacks,
    startFailure: Bool,
    startGate: RoutePipelineAsyncStartGate?,
    stopGate: RoutePipelineAsyncStartGate?
  ) {
    self.telemetry = telemetry
    self.callbacks = callbacks
    self.startFailure = startFailure
    self.startGate = startGate
    self.stopGate = stopGate
  }

  var operations: [RoutePipelineOperation] {
    lock.lock()
    defer { lock.unlock() }
    return recordedOperations
  }

  func start() async throws {
    append(.start)
    if let startGate { await startGate.wait() }
    if startFailure { throw RoutePipelineTestFailure.start }
  }

  func requestKeyframe() { append(.requestKeyframe) }
  func recoverFromEncodedPacketDrop() { append(.recover) }
  func cancel() { append(.cancel) }
  func stop() async {
    append(.stop)
    if let stopGate { await stopGate.wait() }
  }

  func emitAccessUnit(codec: HostPipelineCodec = .h264) {
    callbacks.onAccessUnit(HostMediaAccessUnit(
      codec: codec,
      data: Data([0, 0, 0, 1]),
      presentationTimeUS: 10,
      isKeyframe: true,
      hasParameterSets: true,
      logicalRawFrameCopyCount: 0
    ))
  }

  func emitState() {
    callbacks.onState(HostEncoderRuntimeState(
      hardwareAccelerated: true,
      softwareFallback: false,
      encoderID: "test-encoder"
    ))
  }

  private func append(_ operation: RoutePipelineOperation) {
    lock.lock()
    recordedOperations.append(operation)
    lock.unlock()
  }
}

private final class RecordingRoutePipelineFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let startFailure: Bool
  private let startGate: RoutePipelineAsyncStartGate?
  private let stopGate: RoutePipelineAsyncStartGate?
  private var recordedPipelines: [RecordingRoutePipeline] = []

  init(
    startFailure: Bool = false,
    startGate: RoutePipelineAsyncStartGate? = nil,
    stopGate: RoutePipelineAsyncStartGate? = nil
  ) {
    self.startFailure = startFailure
    self.startGate = startGate
    self.stopGate = stopGate
  }

  var pipelines: [RecordingRoutePipeline] {
    lock.lock()
    defer { lock.unlock() }
    return recordedPipelines
  }

  func make(
    configuration: HostMediaPipelineConfiguration,
    telemetry: HostMediaTelemetry,
    callbacks: HostMediaPipelineRouteCallbacks
  ) throws -> any HostMediaPipelineLifecycle {
    let pipeline = RecordingRoutePipeline(
      telemetry: telemetry,
      callbacks: callbacks,
      startFailure: startFailure,
      startGate: startGate,
      stopGate: stopGate
    )
    lock.lock()
    recordedPipelines.append(pipeline)
    lock.unlock()
    return pipeline
  }
}

private final class RoutePipelineAsyncStartGate: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    entered.signal()
    await withCheckedContinuation { continuation in
      lock.lock()
      if released {
        lock.unlock()
        continuation.resume()
      } else {
        self.continuation = continuation
        lock.unlock()
      }
    }
  }

  func release() {
    lock.lock()
    released = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume()
  }
}

private final class RouteOwnerRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var submissions: [(HostMediaPipelineRouteIdentity, HostMediaAccessUnit)] = []
  private(set) var states: [(HostMediaPipelineRouteIdentity, HostEncoderRuntimeState)] = []
  private(set) var failures: [(HostMediaPipelineRouteIdentity, HostMediaPipelineRouteFailure)] = []
  private(set) var lifecycleEvents: [RouteLifecycleEvent] = []
  private(set) var lifecycleRequestedFPS: [Int] = []

  func recordSubmission(
    route: HostMediaPipelineRouteIdentity,
    unit: HostMediaAccessUnit
  ) {
    lock.lock()
    submissions.append((route, unit))
    lock.unlock()
  }

  func recordState(
    route: HostMediaPipelineRouteIdentity,
    state: HostEncoderRuntimeState
  ) {
    lock.lock()
    states.append((route, state))
    lock.unlock()
  }

  func recordFailure(
    route: HostMediaPipelineRouteIdentity,
    failure: HostMediaPipelineRouteFailure
  ) {
    lock.lock()
    failures.append((route, failure))
    lock.unlock()
  }

  func recordLifecycle(
    _ event: RouteLifecycleEvent,
    requestedFPS: Int
  ) {
    lock.lock()
    lifecycleEvents.append(event)
    lifecycleRequestedFPS.append(requestedFPS)
    lock.unlock()
  }
}

private enum RouteLifecycleEvent: Equatable {
  case started(HostMediaPipelineRouteIdentity)
  case startFailed(HostMediaPipelineRouteIdentity)
  case stopped(HostMediaPipelineRouteIdentity)
}
