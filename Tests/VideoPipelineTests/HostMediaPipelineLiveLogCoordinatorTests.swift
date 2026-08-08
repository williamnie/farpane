@testable import VideoPipeline
import Foundation
import XCTest

final class HostMediaPipelineLiveLogCoordinatorTests: XCTestCase {
  func testRecordsOneRouteLifecycleAndPeriodicSampleWithoutPersistingIdentity() {
    let factory = RecordingLiveLogFactory()
    let coordinator = HostMediaPipelineLiveLogCoordinator(
      writerFactory: { try factory.make() }
    )
    let route = makeIdentity(connectionEpoch: 11, codecEpoch: 21)
    let telemetry = makeTelemetry()

    coordinator.routeStarted(route, telemetry: telemetry)
    coordinator.recordPeriodic()
    coordinator.routeStopped(route, telemetry: telemetry)
    coordinator.recordPeriodic()

    XCTAssertEqual(factory.writers.count, 1)
    XCTAssertEqual(factory.writers[0].events, [
      .routeStarted, .periodic, .routeStopped,
    ])
    let snapshot = coordinator.snapshot()
    XCTAssertFalse(snapshot.hasActiveRoute)
    XCTAssertEqual(snapshot.createdLogCount, 1)
    XCTAssertEqual(snapshot.lifecycleRecordCount, 2)
    XCTAssertEqual(snapshot.periodicRecordCount, 1)
    XCTAssertEqual(snapshot.writerFailureCount, 0)
    XCTAssertEqual(snapshot.rejectedRouteEventCount, 0)
  }

  func testReplacementIsExactRouteScopedAndRejectsStaleTerminalEvent() {
    let factory = RecordingLiveLogFactory()
    let coordinator = HostMediaPipelineLiveLogCoordinator(
      writerFactory: { try factory.make() }
    )
    let first = makeIdentity(connectionEpoch: 11, codecEpoch: 21)
    let second = makeIdentity(connectionEpoch: 12, codecEpoch: 22)
    let telemetry = makeTelemetry()

    coordinator.routeStarted(first, telemetry: telemetry)
    coordinator.routeStopped(first, telemetry: telemetry)
    coordinator.routeStarted(second, telemetry: telemetry)
    coordinator.routeStopped(first, telemetry: telemetry)
    coordinator.recordPeriodic()
    coordinator.routeStopped(second, telemetry: telemetry)

    XCTAssertEqual(factory.writers.count, 2)
    XCTAssertEqual(factory.writers[0].events, [.routeStarted, .routeStopped])
    XCTAssertEqual(factory.writers[1].events, [
      .routeStarted, .periodic, .routeStopped,
    ])
    XCTAssertEqual(coordinator.snapshot().rejectedRouteEventCount, 1)
  }

  func testStartFailureCreatesOnlyBoundedTerminalLog() {
    let factory = RecordingLiveLogFactory()
    let coordinator = HostMediaPipelineLiveLogCoordinator(
      writerFactory: { try factory.make() }
    )

    coordinator.routeStartFailed(
      makeIdentity(connectionEpoch: 11, codecEpoch: 21),
      telemetry: makeTelemetry()
    )
    coordinator.recordPeriodic()

    XCTAssertEqual(factory.writers.count, 1)
    XCTAssertEqual(factory.writers[0].events, [.routeStartFailed])
    let snapshot = coordinator.snapshot()
    XCTAssertFalse(snapshot.hasActiveRoute)
    XCTAssertEqual(snapshot.createdLogCount, 1)
    XCTAssertEqual(snapshot.lifecycleRecordCount, 1)
  }

  func testWriterFailuresAreSanitizedAndCancellationIsTerminal() {
    let factory = RecordingLiveLogFactory(failingEvent: .periodic)
    let coordinator = HostMediaPipelineLiveLogCoordinator(
      writerFactory: { try factory.make() }
    )
    let route = makeIdentity(connectionEpoch: 11, codecEpoch: 21)
    let telemetry = makeTelemetry()

    coordinator.routeStarted(route, telemetry: telemetry)
    coordinator.recordPeriodic()
    coordinator.cancel()
    coordinator.routeStopped(route, telemetry: telemetry)
    coordinator.routeStartFailed(route, telemetry: telemetry)

    let snapshot = coordinator.snapshot()
    XCTAssertTrue(snapshot.cancelled)
    XCTAssertFalse(snapshot.hasActiveRoute)
    XCTAssertEqual(snapshot.writerFailureCount, 1)
    XCTAssertEqual(snapshot.lifecycleRecordCount, 1)
    XCTAssertEqual(snapshot.periodicRecordCount, 0)
    XCTAssertEqual(snapshot.rejectedRouteEventCount, 2)
  }

  func testWriterCreationFailureIsCountedOncePerLifecycleAttempt() {
    let factory = RecordingLiveLogFactory(failCreation: true)
    let coordinator = HostMediaPipelineLiveLogCoordinator(
      writerFactory: { try factory.make() }
    )
    let route = makeIdentity(connectionEpoch: 11, codecEpoch: 21)
    let telemetry = makeTelemetry()

    coordinator.routeStarted(route, telemetry: telemetry)
    coordinator.recordPeriodic()
    coordinator.routeStopped(route, telemetry: telemetry)
    coordinator.routeStartFailed(route, telemetry: telemetry)

    let snapshot = coordinator.snapshot()
    XCTAssertEqual(snapshot.createdLogCount, 0)
    XCTAssertEqual(snapshot.writerFailureCount, 2)
    XCTAssertEqual(snapshot.lifecycleRecordCount, 0)
    XCTAssertEqual(snapshot.periodicRecordCount, 0)
    XCTAssertEqual(snapshot.rejectedRouteEventCount, 0)
  }

  private func makeIdentity(
    connectionEpoch: UInt64,
    codecEpoch: UInt64
  ) -> HostMediaPipelineRouteIdentity {
    HostMediaPipelineRouteIdentity(
      connectionEpoch: connectionEpoch,
      codecEpoch: codecEpoch,
      displayID: 0,
      displayRevision: 3,
      codec: .h264
    )
  }

  private func makeTelemetry() -> HostMediaTelemetry {
    HostMediaTelemetry(configuration: HostMediaPipelineConfiguration(
      codec: .h264,
      displayIndex: 0,
      width: 1_920,
      height: 1_080,
      framesPerSecond: 30,
      bitRate: 4_000_000
    ))
  }
}

private enum RecordingLiveLogError: Error {
  case writeFailed
}

private final class RecordingLiveLogWriter: HostMediaLiveLogRecording, @unchecked Sendable {
  private let lock = NSLock()
  private let failingEvent: HostMediaLiveLogEvent?
  private var recordedEvents: [HostMediaLiveLogEvent] = []

  init(failingEvent: HostMediaLiveLogEvent?) {
    self.failingEvent = failingEvent
  }

  var events: [HostMediaLiveLogEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  func record(
    snapshot: HostMediaTelemetrySnapshot,
    event: HostMediaLiveLogEvent,
    capturedAt: Date,
    monotonicNanoseconds: UInt64
  ) throws -> Bool {
    if event == failingEvent { throw RecordingLiveLogError.writeFailed }
    lock.lock()
    recordedEvents.append(event)
    lock.unlock()
    return true
  }
}

private final class RecordingLiveLogFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let failingEvent: HostMediaLiveLogEvent?
  private let failCreation: Bool
  private var recordedWriters: [RecordingLiveLogWriter] = []

  init(
    failingEvent: HostMediaLiveLogEvent? = nil,
    failCreation: Bool = false
  ) {
    self.failingEvent = failingEvent
    self.failCreation = failCreation
  }

  var writers: [RecordingLiveLogWriter] {
    lock.lock()
    defer { lock.unlock() }
    return recordedWriters
  }

  func make() throws -> any HostMediaLiveLogRecording {
    if failCreation { throw RecordingLiveLogError.writeFailed }
    let writer = RecordingLiveLogWriter(failingEvent: failingEvent)
    lock.lock()
    recordedWriters.append(writer)
    lock.unlock()
    return writer
  }
}
