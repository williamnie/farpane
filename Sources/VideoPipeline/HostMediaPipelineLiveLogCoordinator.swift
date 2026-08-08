import Foundation

package struct HostMediaPipelineLiveLogCoordinatorSnapshot: Sendable {
  package let hasActiveRoute: Bool
  package let createdLogCount: UInt64
  package let lifecycleRecordCount: UInt64
  package let periodicRecordCount: UInt64
  package let writerFailureCount: UInt64
  package let rejectedRouteEventCount: UInt64
  package let cancelled: Bool
}

/// Serializes one bounded, sanitized JSONL writer per active media route.
///
/// Route identities are used only for exact in-memory correlation and are
/// never passed to the writer. Writer errors are reduced to counters so paths
/// and underlying filesystem diagnostics do not enter logs or Core events.
package final class HostMediaPipelineLiveLogCoordinator: @unchecked Sendable {
  package typealias WriterFactory = @Sendable () throws -> any HostMediaLiveLogRecording

  private struct ActiveLog {
    let route: HostMediaPipelineRouteIdentity
    let telemetry: HostMediaTelemetry
    let writer: (any HostMediaLiveLogRecording)?
  }

  private let lock = NSLock()
  private let writerFactory: WriterFactory
  private var activeLog: ActiveLog?
  private var createdLogCount: UInt64 = 0
  private var lifecycleRecordCount: UInt64 = 0
  private var periodicRecordCount: UInt64 = 0
  private var writerFailureCount: UInt64 = 0
  private var rejectedRouteEventCount: UInt64 = 0
  private var cancelled = false

  package init(
    writerFactory: @escaping WriterFactory = {
      try HostMediaTelemetryLiveLogWriter.makeDefault()
    }
  ) {
    self.writerFactory = writerFactory
  }

  package var lifecycleObserver: HostMediaPipelineRouteLifecycleObserver {
    HostMediaPipelineRouteLifecycleObserver(
      onStarted: { [weak self] route, telemetry in
        self?.routeStarted(route, telemetry: telemetry)
      },
      onStartFailed: { [weak self] route, telemetry in
        self?.routeStartFailed(route, telemetry: telemetry)
      },
      onStopped: { [weak self] route, telemetry in
        self?.routeStopped(route, telemetry: telemetry)
      }
    )
  }

  package func routeStarted(
    _ route: HostMediaPipelineRouteIdentity,
    telemetry: HostMediaTelemetry
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled, activeLog == nil else {
      increment(&rejectedRouteEventCount)
      return
    }
    let writer = makeWriterLocked()
    activeLog = ActiveLog(route: route, telemetry: telemetry, writer: writer)
    if recordLocked(writer, telemetry: telemetry, event: .routeStarted) {
      increment(&lifecycleRecordCount)
    }
  }

  package func routeStartFailed(
    _ route: HostMediaPipelineRouteIdentity,
    telemetry: HostMediaTelemetry
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled, activeLog == nil else {
      increment(&rejectedRouteEventCount)
      return
    }
    let writer = makeWriterLocked()
    if recordLocked(writer, telemetry: telemetry, event: .routeStartFailed) {
      increment(&lifecycleRecordCount)
    }
  }

  package func routeStopped(
    _ route: HostMediaPipelineRouteIdentity,
    telemetry: HostMediaTelemetry
  ) {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled,
          let activeLog,
          activeLog.route == route
    else {
      increment(&rejectedRouteEventCount)
      return
    }
    if recordLocked(activeLog.writer, telemetry: telemetry, event: .routeStopped) {
      increment(&lifecycleRecordCount)
    }
    self.activeLog = nil
  }

  package func recordPeriodic() {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled, let activeLog else { return }
    if recordLocked(
      activeLog.writer,
      telemetry: activeLog.telemetry,
      event: .periodic
    ) {
      increment(&periodicRecordCount)
    }
  }

  /// Terminal. The route owner must be drained first so its final lifecycle
  /// callback can persist `routeStopped` before this method clears correlation.
  package func cancel() {
    lock.lock()
    cancelled = true
    activeLog = nil
    lock.unlock()
  }

  package func snapshot() -> HostMediaPipelineLiveLogCoordinatorSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return HostMediaPipelineLiveLogCoordinatorSnapshot(
      hasActiveRoute: activeLog != nil,
      createdLogCount: createdLogCount,
      lifecycleRecordCount: lifecycleRecordCount,
      periodicRecordCount: periodicRecordCount,
      writerFailureCount: writerFailureCount,
      rejectedRouteEventCount: rejectedRouteEventCount,
      cancelled: cancelled
    )
  }

  private func makeWriterLocked() -> (any HostMediaLiveLogRecording)? {
    do {
      let writer = try writerFactory()
      increment(&createdLogCount)
      return writer
    } catch {
      increment(&writerFailureCount)
      return nil
    }
  }

  private func recordLocked(
    _ writer: (any HostMediaLiveLogRecording)?,
    telemetry: HostMediaTelemetry,
    event: HostMediaLiveLogEvent
  ) -> Bool {
    guard let writer else { return false }
    do {
      return try writer.record(
        snapshot: telemetry.snapshot(),
        event: event,
        capturedAt: Date(),
        monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds
      )
    } catch {
      increment(&writerFailureCount)
      return false
    }
  }

  private func increment(_ value: inout UInt64) {
    if value < UInt64.max { value += 1 }
  }
}
