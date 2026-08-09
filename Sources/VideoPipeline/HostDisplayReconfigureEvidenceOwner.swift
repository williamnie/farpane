import Foundation

package struct HostDisplayReconfigureEvidenceMarker:
  Equatable,
  Sendable
{
  package let generation: UInt64
  package let displayID: UInt64
  package let previousDisplayRevision: UInt64
  package let previousConnectionEpoch: UInt64
  package let previousCodecEpoch: UInt64

  package init(
    generation: UInt64,
    displayID: UInt64,
    previousDisplayRevision: UInt64,
    previousConnectionEpoch: UInt64,
    previousCodecEpoch: UInt64
  ) {
    self.generation = generation
    self.displayID = displayID
    self.previousDisplayRevision = previousDisplayRevision
    self.previousConnectionEpoch = previousConnectionEpoch
    self.previousCodecEpoch = previousCodecEpoch
  }
}

package struct HostDisplayReconfigureEvidenceCandidate:
  Equatable,
  Sendable
{
  package let marker: HostDisplayReconfigureEvidenceMarker
  package let replacementRoute: HostMediaPipelineRouteIdentity

  package init(
    marker: HostDisplayReconfigureEvidenceMarker,
    replacementRoute: HostMediaPipelineRouteIdentity
  ) {
    self.marker = marker
    self.replacementRoute = replacementRoute
  }
}

package struct HostDisplayReconfigureEvidenceStart:
  Equatable,
  Sendable
{
  package let marker: HostDisplayReconfigureEvidenceMarker
  package let connectionEpoch: UInt64
  package let codecEpoch: UInt64
  package let displayID: UInt64
  package let displayRevision: UInt64

  package init(
    marker: HostDisplayReconfigureEvidenceMarker,
    connectionEpoch: UInt64,
    codecEpoch: UInt64,
    displayID: UInt64,
    displayRevision: UInt64
  ) {
    self.marker = marker
    self.connectionEpoch = connectionEpoch
    self.codecEpoch = codecEpoch
    self.displayID = displayID
    self.displayRevision = displayRevision
  }
}

package enum HostDisplayReconfigureEvidenceOutcome:
  Equatable,
  Sendable
{
  case converged
  case rejected
  case failed
  case timedOut
  case unavailable
}

package enum HostDisplayReconfigureEvidenceState:
  Equatable,
  Sendable
{
  case idle
  case accepting(generation: UInt64)
  case awaitingStart(HostDisplayReconfigureEvidenceMarker)
  case awaitingReconfigure(HostDisplayReconfigureEvidenceStart)
  case polling(HostDisplayReconfigureEvidenceCandidate)
  case completed(
    generation: UInt64,
    outcome: HostDisplayReconfigureEvidenceOutcome
  )
  case cancelling
  case cancelled
}

/// Correlates the Rust display-inventory marker with both replacement media
/// controls and the process-owned asynchronous route authority. Evidence I/O
/// is observation-only and can never reject or terminate the media route.
package final class HostDisplayReconfigureEvidenceOwner:
  @unchecked Sendable
{
  package typealias RoutePoll = @Sendable (
    HostMediaPipelineRouteIdentity
  ) -> HostMediaPipelineRecoveryConvergence

  private final class RouteReference: @unchecked Sendable {
    private let lock = NSLock()
    private var route: HostMediaPipelineRouteIdentity?

    func store(_ route: HostMediaPipelineRouteIdentity?) {
      lock.lock()
      self.route = route
      lock.unlock()
    }

    func load() -> HostMediaPipelineRouteIdentity? {
      lock.lock()
      defer { lock.unlock() }
      return route
    }
  }

  private let condition = NSCondition()
  private let evidenceOwner: HostRecoveryTransitionEvidenceProcessOwner
  private let routeReference: RouteReference
  private let pollingOwner: HostMediaPipelineRecoveryPollingOwner
  private var state: HostDisplayReconfigureEvidenceState = .idle
  private var lastGeneration: UInt64 = 0
  private var acceptanceInFlight = false

  package init(
    evidenceOwner: HostRecoveryTransitionEvidenceProcessOwner,
    routePoll: @escaping RoutePoll
  ) {
    let routeReference = RouteReference()
    self.evidenceOwner = evidenceOwner
    self.routeReference = routeReference
    self.pollingOwner = HostMediaPipelineRecoveryPollingOwner.makeProduct(
      queue: DispatchQueue(
        label: "io.farpane.host-display-reconfigure-evidence",
        qos: .utility
      ),
      poll: {
        guard let route = routeReference.load() else { return .failed }
        return routePoll(route)
      }
    )
  }

  deinit {
    cancelAndWait()
  }

  package func snapshot() -> HostDisplayReconfigureEvidenceState {
    condition.lock()
    defer { condition.unlock() }
    return state
  }

  /// Accepts only a strictly newer, nonzero Rust-authoritative marker.
  @discardableResult
  package func accept(
    _ marker: HostDisplayReconfigureEvidenceMarker
  ) -> Bool {
    guard Self.isValid(marker) else { return false }
    condition.lock()
    guard marker.generation > lastGeneration else {
      condition.unlock()
      return false
    }
    switch state {
    case .idle, .completed:
      state = .accepting(generation: marker.generation)
      acceptanceInFlight = true
      lastGeneration = marker.generation
      condition.unlock()
    case .accepting, .awaitingStart, .awaitingReconfigure, .polling,
         .cancelling, .cancelled:
      condition.unlock()
      return false
    }

    let accepted = evidenceOwner.acceptDisplayReconfigure(
      generation: marker.generation,
      displayID: marker.displayID,
      previousDisplayRevision: marker.previousDisplayRevision,
      previousConnectionEpoch: marker.previousConnectionEpoch,
      previousCodecEpoch: marker.previousCodecEpoch
    )

    condition.lock()
    acceptanceInFlight = false
    let remainsCurrent = state == .accepting(generation: marker.generation)
    if remainsCurrent {
      state = accepted
        ? .awaitingStart(marker)
        : .completed(generation: marker.generation, outcome: .unavailable)
    }
    condition.broadcast()
    condition.unlock()
    if accepted && !remainsCurrent {
      _ = evidenceOwner.discardDisplayReconfigure(
        generation: marker.generation
      )
    }
    return accepted && remainsCurrent
  }

  /// Observes every start control. A pending display marker must have the
  /// exact typed provenance; an ordinary route never creates display proof.
  @discardableResult
  package func observeStart(
    _ start: HostDisplayReconfigureEvidenceStart?
  ) -> Bool {
    condition.lock()
    switch state {
    case .awaitingStart(let marker):
      guard let start, Self.matches(start, marker: marker) else {
        state = .completed(generation: marker.generation, outcome: .rejected)
        condition.unlock()
        _ = evidenceOwner.discardDisplayReconfigure(
          generation: marker.generation
        )
        return false
      }
      state = .awaitingReconfigure(start)
      condition.unlock()
      return true
    case .idle, .completed:
      condition.unlock()
      return start == nil
    case .accepting, .awaitingReconfigure, .polling, .cancelling,
         .cancelled:
      condition.unlock()
      return false
    }
  }

  /// Starts bounded convergence polling only after the exact replacement
  /// reconfigure has been accepted by the route owner.
  @discardableResult
  package func observeReconfigure(
    _ candidate: HostDisplayReconfigureEvidenceCandidate?,
    routeAccepted: Bool
  ) -> Bool {
    condition.lock()
    switch state {
    case .awaitingReconfigure(let start):
      guard routeAccepted,
            let candidate,
            Self.matches(candidate, start: start)
      else {
        state = .completed(
          generation: start.marker.generation,
          outcome: .rejected
        )
        condition.unlock()
        _ = evidenceOwner.discardDisplayReconfigure(
          generation: start.marker.generation
        )
        return false
      }
      state = .polling(candidate)
      routeReference.store(candidate.replacementRoute)
      condition.unlock()
      let started = pollingOwner.start(epoch: candidate.marker.generation) {
        [weak self] generation, outcome in
        self?.complete(
          candidate,
          generation: generation,
          outcome: outcome
        )
      }
      guard started else {
        finishRejected(candidate, outcome: .failed)
        return false
      }
      return true
    case .idle, .completed:
      condition.unlock()
      return candidate == nil
    case .accepting, .awaitingStart, .polling, .cancelling, .cancelled:
      condition.unlock()
      return false
    }
  }

  package func cancelAndWait() {
    condition.lock()
    switch state {
    case .cancelled:
      condition.unlock()
      return
    case .cancelling:
      while state == .cancelling {
        condition.wait()
      }
      condition.unlock()
      return
    case .idle, .accepting, .awaitingStart, .awaitingReconfigure,
         .polling, .completed:
      let generation = state.generation
      state = .cancelling
      while acceptanceInFlight {
        condition.wait()
      }
      condition.unlock()
      pollingOwner.cancelAndWait()
      routeReference.store(nil)
      if let generation {
        _ = evidenceOwner.discardDisplayReconfigure(generation: generation)
      }
    }

    condition.lock()
    state = .cancelled
    condition.broadcast()
    condition.unlock()
  }

  private func complete(
    _ candidate: HostDisplayReconfigureEvidenceCandidate,
    generation: UInt64,
    outcome: HostMediaPipelineRecoveryPollingOutcome
  ) {
    guard generation == candidate.marker.generation else { return }
    let evidenceOutcome: HostDisplayReconfigureEvidenceOutcome
    switch outcome {
    case .converged:
      let marker = candidate.marker
      let route = candidate.replacementRoute
      let recorded = evidenceOwner.recordDisplayReconfigureCompleted(
        generation: marker.generation,
        displayID: marker.displayID,
        previousDisplayRevision: marker.previousDisplayRevision,
        replacementDisplayRevision: route.displayRevision,
        previousConnectionEpoch: marker.previousConnectionEpoch,
        replacementConnectionEpoch: route.connectionEpoch,
        previousCodecEpoch: marker.previousCodecEpoch,
        replacementCodecEpoch: route.codecEpoch
      )
      evidenceOutcome = recorded ? .converged : .unavailable
    case .failed:
      _ = evidenceOwner.discardDisplayReconfigure(generation: generation)
      evidenceOutcome = .failed
    case .timedOut:
      _ = evidenceOwner.discardDisplayReconfigure(generation: generation)
      evidenceOutcome = .timedOut
    }
    routeReference.store(nil)
    condition.lock()
    if state == .polling(candidate) {
      state = .completed(generation: generation, outcome: evidenceOutcome)
    }
    condition.broadcast()
    condition.unlock()
  }

  private func finishRejected(
    _ candidate: HostDisplayReconfigureEvidenceCandidate,
    outcome: HostDisplayReconfigureEvidenceOutcome
  ) {
    routeReference.store(nil)
    _ = evidenceOwner.discardDisplayReconfigure(
      generation: candidate.marker.generation
    )
    condition.lock()
    if state == .polling(candidate) {
      state = .completed(
        generation: candidate.marker.generation,
        outcome: outcome
      )
    }
    condition.broadcast()
    condition.unlock()
  }

  private static func isValid(
    _ marker: HostDisplayReconfigureEvidenceMarker
  ) -> Bool {
    marker.generation > 0
      && marker.previousDisplayRevision > 0
      && marker.previousDisplayRevision < UInt64.max
      && marker.previousConnectionEpoch > 0
      && marker.previousCodecEpoch > 0
  }

  private static func matches(
    _ start: HostDisplayReconfigureEvidenceStart,
    marker: HostDisplayReconfigureEvidenceMarker
  ) -> Bool {
    start.marker == marker
      && start.displayID == marker.displayID
      && start.displayRevision == marker.previousDisplayRevision + 1
      && start.connectionEpoch > marker.previousConnectionEpoch
      && start.codecEpoch > marker.previousCodecEpoch
  }

  private static func matches(
    _ candidate: HostDisplayReconfigureEvidenceCandidate,
    start: HostDisplayReconfigureEvidenceStart
  ) -> Bool {
    let route = candidate.replacementRoute
    return candidate.marker == start.marker
      && route.connectionEpoch == start.connectionEpoch
      && route.codecEpoch == start.codecEpoch
      && route.displayID == start.displayID
      && route.displayRevision == start.displayRevision
  }
}

private extension HostDisplayReconfigureEvidenceState {
  var generation: UInt64? {
    switch self {
    case .accepting(let generation),
         .completed(let generation, _):
      return generation
    case .awaitingStart(let marker):
      return marker.generation
    case .awaitingReconfigure(let start):
      return start.marker.generation
    case .polling(let candidate):
      return candidate.marker.generation
    case .idle, .cancelling, .cancelled:
      return nil
    }
  }
}
