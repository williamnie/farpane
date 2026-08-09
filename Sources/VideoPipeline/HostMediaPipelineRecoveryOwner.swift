import Foundation

package enum HostMediaPipelineRecoveryStatus: Equatable, Sendable {
  case active
  case suspending
  case suspended
  case awaitingFreshRoute
  case failed
  case cancelling
  case cancelled
}

package struct HostMediaPipelineRecoverySnapshot: Equatable, Sendable {
  package let status: HostMediaPipelineRecoveryStatus
  package let epoch: UInt64
  package let previousRoute: HostMediaPipelineRouteIdentity?
}

/// Adds a nonterminal sleep boundary around the process-owned media route.
/// Sleep rejects new route work, waits for admitted controls, then stops and
/// drains ScreenCaptureKit/VideoToolbox. Wake never replays the old route:
/// a rebuilt pipeline must arrive with a newer connection or codec epoch so
/// its presentation timestamps cannot be mistaken for late packets.
package final class HostMediaPipelineRecoveryOwner: @unchecked Sendable {
  private enum State {
    case active(epoch: UInt64)
    case suspending(epoch: UInt64)
    case suspended(epoch: UInt64, previousRoute: HostMediaPipelineRouteIdentity?)
    case awaitingFreshRoute(
      epoch: UInt64,
      previousRoute: HostMediaPipelineRouteIdentity
    )
    case resuming(
      epoch: UInt64,
      previousRoute: HostMediaPipelineRouteIdentity
    )
    case failed(epoch: UInt64)
    case cancelling(epoch: UInt64)
    case cancelled(epoch: UInt64)
  }

  private enum ReconfigureAdmission {
    case active(epoch: UInt64)
    case recovery(epoch: UInt64, previousRoute: HostMediaPipelineRouteIdentity)
  }

  private let condition = NSCondition()
  private let routeOwner: HostMediaPipelineRouteOwner
  private var state: State = .active(epoch: 0)
  private var controlInFlight = 0
  private var recoveryInFlight = false

  package init(routeOwner: HostMediaPipelineRouteOwner) {
    self.routeOwner = routeOwner
  }

  @discardableResult
  package func acceptStartCapture() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    switch state {
    case .active, .awaitingFreshRoute:
      return true
    case .suspending, .suspended, .resuming, .failed, .cancelling, .cancelled:
      return false
    }
  }

  @discardableResult
  package func reconfigure(_ route: HostMediaPipelineRoute) -> Bool {
    condition.lock()
    let admission: ReconfigureAdmission
    switch state {
    case .active(let epoch):
      admission = .active(epoch: epoch)
    case .awaitingFreshRoute(let epoch, let previousRoute):
      guard Self.isFresh(route.identity, after: previousRoute) else {
        condition.unlock()
        return false
      }
      state = .resuming(epoch: epoch, previousRoute: previousRoute)
      admission = .recovery(epoch: epoch, previousRoute: previousRoute)
    case .suspending, .suspended, .resuming, .failed, .cancelling, .cancelled:
      condition.unlock()
      return false
    }
    controlInFlight += 1
    condition.unlock()

    let accepted = routeOwner.reconfigure(route)

    condition.lock()
    controlInFlight -= 1
    switch admission {
    case .active:
      break
    case .recovery(let epoch, let previousRoute):
      if case .resuming(epoch, previousRoute) = state {
        state = accepted
          ? .active(epoch: epoch)
          : .awaitingFreshRoute(epoch: epoch, previousRoute: previousRoute)
      }
    }
    condition.broadcast()
    condition.unlock()
    return accepted
  }

  @discardableResult
  package func requestKeyframe(
    route: HostMediaPipelineRouteIdentity
  ) -> Bool {
    guard beginActiveControl() else { return false }
    let accepted = routeOwner.requestKeyframe(route: route)
    finishControl()
    return accepted
  }

  @discardableResult
  package func stop(route: HostMediaPipelineRouteIdentity) -> Bool {
    condition.lock()
    switch state {
    case .active:
      controlInFlight += 1
      condition.unlock()
      let accepted = routeOwner.stop(route: route)
      finishControl()
      return accepted

    case .suspended(let epoch, let previousRoute) where previousRoute == route:
      state = .suspended(epoch: epoch, previousRoute: nil)
      condition.unlock()
      return true

    case .awaitingFreshRoute(let epoch, let previousRoute)
      where previousRoute == route:
      state = .active(epoch: epoch)
      condition.unlock()
      return true

    case .suspending, .suspended, .awaitingFreshRoute, .resuming,
         .failed, .cancelling, .cancelled:
      condition.unlock()
      return false
    }
  }

  /// Nonterminal and synchronous. Once this returns true, no active or desired
  /// route remains and all queued capture/encoder lifecycle work has drained.
  @discardableResult
  package func pauseAndFlushForSleep() -> Bool {
    condition.lock()
    guard case .active(let currentEpoch) = state,
          currentEpoch < UInt64.max
    else {
      condition.unlock()
      return false
    }
    let epoch = currentEpoch + 1
    state = .suspending(epoch: epoch)
    recoveryInFlight = true
    while controlInFlight > 0 {
      condition.wait()
    }
    condition.unlock()

    let before = routeOwner.snapshot()
    let previousRoute = before.desiredRoute ?? before.activeRoute
    if let previousRoute {
      _ = routeOwner.stop(route: previousRoute)
    }
    routeOwner.waitUntilIdle()
    let after = routeOwner.snapshot()
    let drained = after.desiredRoute == nil
      && after.activeRoute == nil
      && after.pendingOperationCount == 0

    condition.lock()
    recoveryInFlight = false
    guard case .suspending(epoch) = state else {
      condition.broadcast()
      condition.unlock()
      return false
    }
    if drained {
      state = .suspended(epoch: epoch, previousRoute: previousRoute)
      condition.broadcast()
      condition.unlock()
      return true
    }
    state = .failed(epoch: epoch)
    condition.broadcast()
    condition.unlock()
    return false
  }

  /// Reopens control ingress after display and permission revalidation. When a
  /// route existed before sleep, only a fresh authoritative route may rebuild
  /// media; this method does not replay stale capture/encoder configuration.
  @discardableResult
  package func resumeAfterWake() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard case .suspended(let epoch, let previousRoute) = state else {
      return false
    }
    if let previousRoute {
      state = .awaitingFreshRoute(
        epoch: epoch,
        previousRoute: previousRoute
      )
    } else {
      state = .active(epoch: epoch)
    }
    return true
  }

  package func routeIdentities() -> [HostMediaPipelineRouteIdentity] {
    var routes = routeOwner.routeIdentities()
    condition.lock()
    let previousRoute: HostMediaPipelineRouteIdentity?
    switch state {
    case .suspended(_, let route):
      previousRoute = route
    case .awaitingFreshRoute(_, let route), .resuming(_, let route):
      previousRoute = route
    case .active, .suspending, .failed, .cancelling, .cancelled:
      previousRoute = nil
    }
    condition.unlock()
    if let previousRoute, !routes.contains(previousRoute) {
      routes.append(previousRoute)
    }
    return routes
  }

  package func snapshot() -> HostMediaPipelineRecoverySnapshot {
    condition.lock()
    defer { condition.unlock() }
    switch state {
    case .active(let epoch):
      return .init(status: .active, epoch: epoch, previousRoute: nil)
    case .suspending(let epoch):
      return .init(status: .suspending, epoch: epoch, previousRoute: nil)
    case .suspended(let epoch, let route):
      return .init(status: .suspended, epoch: epoch, previousRoute: route)
    case .awaitingFreshRoute(let epoch, let route),
         .resuming(let epoch, let route):
      return .init(status: .awaitingFreshRoute, epoch: epoch, previousRoute: route)
    case .failed(let epoch):
      return .init(status: .failed, epoch: epoch, previousRoute: nil)
    case .cancelling(let epoch):
      return .init(status: .cancelling, epoch: epoch, previousRoute: nil)
    case .cancelled(let epoch):
      return .init(status: .cancelled, epoch: epoch, previousRoute: nil)
    }
  }

  /// Terminal and idempotent. A concurrent sleep flush is allowed to finish
  /// before the underlying route owner is sealed.
  package func cancelAndWait() {
    condition.lock()
    let epoch: UInt64
    switch state {
    case .cancelled:
      condition.unlock()
      return
    case .cancelling:
      while case .cancelling = state {
        condition.wait()
      }
      condition.unlock()
      return
    case .active(let value), .suspending(let value), .suspended(let value, _),
         .awaitingFreshRoute(let value, _), .resuming(let value, _),
         .failed(let value):
      epoch = value
      state = .cancelling(epoch: value)
      while controlInFlight > 0 || recoveryInFlight {
        condition.wait()
      }
      condition.unlock()
    }

    routeOwner.cancelAndWait()

    condition.lock()
    state = .cancelled(epoch: epoch)
    condition.broadcast()
    condition.unlock()
  }

  private func beginActiveControl() -> Bool {
    condition.lock()
    guard case .active = state else {
      condition.unlock()
      return false
    }
    controlInFlight += 1
    condition.unlock()
    return true
  }

  private func finishControl() {
    condition.lock()
    controlInFlight -= 1
    condition.broadcast()
    condition.unlock()
  }

  private static func isFresh(
    _ candidate: HostMediaPipelineRouteIdentity,
    after previous: HostMediaPipelineRouteIdentity
  ) -> Bool {
    candidate.connectionEpoch > previous.connectionEpoch
      || (candidate.connectionEpoch == previous.connectionEpoch
        && candidate.codecEpoch > previous.codecEpoch)
  }
}
