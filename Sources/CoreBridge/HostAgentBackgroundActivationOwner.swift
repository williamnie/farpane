import Foundation

package protocol HostAgentBackgroundActivationRuntime:
    AnyObject,
    Sendable
{
    func readinessSnapshot() -> HostAgentBackgroundReadinessView
    func projectionSnapshot() -> HostAgentBackgroundProjectionView?
    func commandAvailabilitySnapshot()
        -> HostAgentXPCReconnectCommandAvailability
    @discardableResult
    func submitCommand(
        route: HostAgentXPCReconnectCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool
    @discardableResult
    func retryCommand(
        route: HostAgentXPCReconnectCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool
    @discardableResult
    func startMonitoring() -> Bool
    func refreshRegistrationObservation()
    func cancelMonitoring()
}

extension HostAgentBackgroundActivationRuntime {
    package func projectionSnapshot()
        -> HostAgentBackgroundProjectionView?
    {
        nil
    }

    package func commandAvailabilitySnapshot()
        -> HostAgentXPCReconnectCommandAvailability
    {
        .unavailable
    }

    package func submitCommand(
        route: HostAgentXPCReconnectCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        false
    }

    package func retryCommand(
        route: HostAgentXPCReconnectCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        false
    }
}

extension HostAgentBackgroundRuntimeComposition:
    HostAgentBackgroundActivationRuntime
{
    package func readinessSnapshot() -> HostAgentBackgroundReadinessView {
        healthAuthority.snapshot()
    }

    package func projectionSnapshot()
        -> HostAgentBackgroundProjectionView?
    {
        projectionAuthority.snapshot()
    }

    package func commandAvailabilitySnapshot()
        -> HostAgentXPCReconnectCommandAvailability
    {
        reconnectOwner.commandAvailabilitySnapshot()
    }

    package func submitCommand(
        route: HostAgentXPCReconnectCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        reconnectOwner.submitCommand(
            route: route,
            intent: intent,
            observer: observer
        )
    }

    package func retryCommand(
        route: HostAgentXPCReconnectCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        reconnectOwner.retryCommand(route: route, observer: observer)
    }

    @discardableResult
    package func startMonitoring() -> Bool {
        reconnectOwner.start()
    }

    package func refreshRegistrationObservation() {
        refreshRegistration()
    }

    package func cancelMonitoring() {
        reconnectOwner.cancel()
    }
}

package enum HostAgentBackgroundActivationIntent: Equatable, Sendable {
    case hostEnabled
    case hostDisabled
    case applicationWillTerminate
}

package enum HostAgentBackgroundActivationFailure: Equatable, Sendable {
    case runtimeCreation
    case runtimeStartRejected
    case invalidHealthSequence
    case runtimeHealthRejected
    case generationExhausted
}

package enum HostAgentBackgroundActivationPhase: Equatable, Sendable {
    case idle
    case starting(epoch: UInt64)
    case monitoring(
        epoch: UInt64,
        readiness: HostAgentBackgroundReadinessView
    )
    case disabled
    case failed(HostAgentBackgroundActivationFailure)
    case terminated
}

package struct HostAgentBackgroundActivationView: Equatable, Sendable {
    package let generation: UInt64
    package let phase: HostAgentBackgroundActivationPhase
    package let projection: HostAgentBackgroundProjectionView?

    fileprivate init(
        generation: UInt64,
        phase: HostAgentBackgroundActivationPhase,
        projection: HostAgentBackgroundProjectionView? = nil
    ) {
        self.generation = generation
        self.phase = phase
        self.projection = projection
    }
}

/// App-side owner that is activated only by an explicit typed product intent.
/// Each enable epoch receives a fresh one-shot runtime composition; disabling
/// only stops local observation and does not mutate registration or Host data.
package final class HostAgentBackgroundActivationOwner:
    @unchecked Sendable
{
    package typealias RuntimeFactory = @Sendable (
        _ observer: @escaping HostAgentBackgroundHealthAuthority.Observer
    ) throws -> HostAgentBackgroundActivationRuntime
    package typealias Observer = @Sendable
        (HostAgentBackgroundActivationView) -> Void

    private struct CommandContext {
        let activationEpoch: UInt64
        let projectionGeneration: UInt64
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let projection: HostAgentBackgroundProjection
        let runtime: HostAgentBackgroundActivationRuntime
    }

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let makeRuntime: RuntimeFactory
    private let observer: Observer
    private var view = HostAgentBackgroundActivationView(
        generation: 0,
        phase: .idle
    )
    private var activationEpoch: UInt64 = 0
    private var activeEpoch: UInt64?
    private var activeRuntime: HostAgentBackgroundActivationRuntime?

    package static func makeProduct(
        observer: @escaping Observer = { _ in }
    ) -> HostAgentBackgroundActivationOwner {
        HostAgentBackgroundActivationOwner(
            makeRuntime: { healthObserver in
                HostAgentBackgroundRuntimeComposition.makeProduct(
                    observer: healthObserver
                )
            },
            observer: observer
        )
    }

    package init(
        makeRuntime: @escaping RuntimeFactory,
        observer: @escaping Observer = { _ in }
    ) {
        self.makeRuntime = makeRuntime
        self.observer = observer
    }

    deinit {
        stateLock.lock()
        let runtime = activeRuntime
        activeRuntime = nil
        activeEpoch = nil
        stateLock.unlock()
        runtime?.cancelMonitoring()
    }

    package func snapshot() -> HostAgentBackgroundActivationView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func apply(
        _ intent: HostAgentBackgroundActivationIntent
    ) -> Bool {
        switch intent {
        case .hostEnabled:
            return enable()
        case .hostDisabled:
            return stop(phase: .disabled, terminal: false)
        case .applicationWillTerminate:
            return stop(phase: .terminated, terminal: true)
        }
    }

    package func refreshRegistration() {
        stateLock.lock()
        let runtime: HostAgentBackgroundActivationRuntime?
        if case .monitoring = view.phase {
            runtime = activeRuntime
        } else {
            runtime = nil
        }
        stateLock.unlock()
        runtime?.refreshRegistrationObservation()
    }

    package func commandAvailabilitySnapshot()
        -> HostAgentBackgroundCommandAvailability
    {
        guard let context = currentCommandContext() else {
            return .unavailable
        }
        let runtimeAvailability = context.runtime
            .commandAvailabilitySnapshot()
        guard commandContextIsCurrent(context) else {
            return .unavailable
        }
        switch runtimeAvailability {
        case .unavailable:
            return .unavailable
        case .available(let reconnectRoute, let commandState):
            guard reconnectRoute.peerIdentity == context.peerIdentity,
                  commandStateMatchesProjection(
                    commandState,
                    projection: context.projection
                  )
            else { return .unavailable }
            return .available(
                route: HostAgentBackgroundCommandRoute(
                    activationEpoch: context.activationEpoch,
                    projectionGeneration: context.projectionGeneration,
                    reconnectRoute: reconnectRoute
                ),
                state: commandState
            )
        }
    }

    @discardableResult
    package func submitCommand(
        route: HostAgentBackgroundCommandRoute,
        intent: HostAgentXPCCommandIntent,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        guard let context = currentCommandContext(route: route),
              projectionAllows(intent, projection: context.projection),
              context.runtime.commandAvailabilitySnapshot()
                == .available(route: route.reconnectRoute, state: .idle),
              commandContextIsCurrent(context)
        else { return false }
        let relay = HostAgentBackgroundCommandObserverRelay(
            owner: self,
            route: route,
            observer: observer
        )
        return context.runtime.submitCommand(
            route: route.reconnectRoute,
            intent: intent,
            observer: { result in relay.publish(result) }
        )
    }

    @discardableResult
    package func retryCommand(
        route: HostAgentBackgroundCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool {
        guard let context = currentCommandContext(route: route),
              case .available(
                route: route.reconnectRoute,
                state: .retryable(let intent)
              ) = context.runtime.commandAvailabilitySnapshot(),
              projectionAllows(intent, projection: context.projection),
              commandContextIsCurrent(context)
        else { return false }
        let relay = HostAgentBackgroundCommandObserverRelay(
            owner: self,
            route: route,
            observer: observer
        )
        return context.runtime.retryCommand(
            route: route.reconnectRoute,
            observer: { result in relay.publish(result) }
        )
    }

    private func enable() -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        switch view.phase {
        case .starting, .monitoring:
            stateLock.unlock()
            deliveryLock.unlock()
            return true
        case .terminated:
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        case .idle, .disabled, .failed:
            break
        }
        guard activationEpoch < UInt64.max else {
            let publication = replaceViewLocked(
                .failed(.generationExhausted)
            )
            stateLock.unlock()
            publish(publication)
            deliveryLock.unlock()
            return false
        }
        activationEpoch += 1
        let epoch = activationEpoch
        activeEpoch = epoch
        let publication = replaceViewLocked(.starting(epoch: epoch))
        if publication.phase == .failed(.generationExhausted) {
            activeEpoch = nil
            invalidateEpochLocked()
        }
        stateLock.unlock()
        publish(publication)
        deliveryLock.unlock()

        stateLock.lock()
        let shouldCreateRuntime = activeEpoch == epoch
            && activeRuntime == nil
            && view.phase == .starting(epoch: epoch)
        stateLock.unlock()
        guard shouldCreateRuntime else { return false }

        let runtime: HostAgentBackgroundActivationRuntime
        do {
            runtime = try makeRuntime { [weak self] readiness in
                self?.acceptReadiness(readiness, activationEpoch: epoch)
            }
        } catch {
            failCreation(activationEpoch: epoch)
            return false
        }

        guard install(runtime, activationEpoch: epoch) else { return false }
        guard runtime.startMonitoring() else {
            failRuntime(
                runtime,
                activationEpoch: epoch,
                failure: .runtimeStartRejected
            )
            return false
        }

        stateLock.lock()
        let remainsCurrent = activeEpoch == epoch
            && sameRuntime(activeRuntime, runtime)
            && isMonitoring(view.phase, activationEpoch: epoch)
        stateLock.unlock()
        return remainsCurrent
    }

    private func install(
        _ runtime: HostAgentBackgroundActivationRuntime,
        activationEpoch: UInt64
    ) -> Bool {
        let initialReadiness = runtime.readinessSnapshot()
        let initialProjection = runtime.projectionSnapshot()
        deliveryLock.lock()
        stateLock.lock()
        guard activeEpoch == activationEpoch,
              activeRuntime == nil,
              view.phase == .starting(epoch: activationEpoch)
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            runtime.cancelMonitoring()
            return false
        }
        activeRuntime = runtime
        let publication = replaceViewLocked(
            .monitoring(
                epoch: activationEpoch,
                readiness: initialReadiness
            ),
            projection: coherentProjection(
                initialProjection,
                readiness: initialReadiness
            )
        )
        let generationFailed = publication.phase
            == .failed(.generationExhausted)
        if generationFailed {
            activeRuntime = nil
            activeEpoch = nil
            invalidateEpochLocked()
        }
        stateLock.unlock()
        if generationFailed {
            runtime.cancelMonitoring()
        }
        publish(publication)
        deliveryLock.unlock()
        guard !generationFailed else { return false }

        stateLock.lock()
        let remainsCurrent = activeEpoch == activationEpoch
            && sameRuntime(activeRuntime, runtime)
            && isMonitoring(
                view.phase,
                activationEpoch: activationEpoch
            )
        stateLock.unlock()
        return remainsCurrent
    }

    private func failCreation(activationEpoch: UInt64) {
        deliveryLock.lock()
        stateLock.lock()
        guard activeEpoch == activationEpoch,
              activeRuntime == nil,
              view.phase == .starting(epoch: activationEpoch)
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return
        }
        invalidateEpochLocked()
        activeEpoch = nil
        let publication = replaceViewLocked(.failed(.runtimeCreation))
        stateLock.unlock()
        publish(publication)
        deliveryLock.unlock()
    }

    private func failRuntime(
        _ runtime: HostAgentBackgroundActivationRuntime,
        activationEpoch: UInt64,
        failure: HostAgentBackgroundActivationFailure
    ) {
        deliveryLock.lock()
        stateLock.lock()
        guard activeEpoch == activationEpoch,
              sameRuntime(activeRuntime, runtime),
              isMonitoring(view.phase, activationEpoch: activationEpoch)
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return
        }
        activeRuntime = nil
        activeEpoch = nil
        invalidateEpochLocked()
        let publication = replaceViewLocked(.failed(failure))
        stateLock.unlock()
        runtime.cancelMonitoring()
        publish(publication)
        deliveryLock.unlock()
    }

    private func acceptReadiness(
        _ readiness: HostAgentBackgroundReadinessView,
        activationEpoch: UInt64
    ) {
        deliveryLock.lock()
        stateLock.lock()
        guard activeEpoch == activationEpoch,
              let runtime = activeRuntime,
              case .monitoring(let epoch, let current) = view.phase,
              epoch == activationEpoch
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return
        }

        let failure: HostAgentBackgroundActivationFailure?
        let runtimeProjection = runtime.projectionSnapshot()
        if readiness.failure != nil {
            failure = .runtimeHealthRejected
        } else if runtimeProjection != nil,
                  coherentProjection(
                    runtimeProjection,
                    readiness: readiness
                  ) == nil
        {
            failure = .invalidHealthSequence
        } else if readiness.generation < current.generation {
            stateLock.unlock()
            deliveryLock.unlock()
            return
        } else if readiness.generation == current.generation {
            if readiness == current {
                stateLock.unlock()
                deliveryLock.unlock()
                return
            }
            failure = .invalidHealthSequence
        } else {
            failure = nil
        }

        if let failure {
            activeRuntime = nil
            activeEpoch = nil
            invalidateEpochLocked()
            let publication = replaceViewLocked(.failed(failure))
            stateLock.unlock()
            runtime.cancelMonitoring()
            publish(publication)
        } else {
            let publication = replaceViewLocked(
                .monitoring(
                    epoch: activationEpoch,
                    readiness: readiness
                ),
                projection: coherentProjection(
                    runtimeProjection,
                    readiness: readiness
                )
            )
            let generationFailed = publication.phase
                == .failed(.generationExhausted)
            if generationFailed {
                activeRuntime = nil
                activeEpoch = nil
                invalidateEpochLocked()
            }
            stateLock.unlock()
            if generationFailed {
                runtime.cancelMonitoring()
            }
            publish(publication)
        }
        deliveryLock.unlock()
    }

    private func stop(
        phase: HostAgentBackgroundActivationPhase,
        terminal: Bool
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        if case .terminated = view.phase {
            stateLock.unlock()
            deliveryLock.unlock()
            return terminal
        }
        if !terminal, view.phase == .disabled {
            stateLock.unlock()
            deliveryLock.unlock()
            return true
        }
        let runtime = activeRuntime
        activeRuntime = nil
        activeEpoch = nil
        invalidateEpochLocked()
        let publication = replaceViewLocked(phase)
        stateLock.unlock()
        runtime?.cancelMonitoring()
        publish(publication)
        deliveryLock.unlock()
        return true
    }

    private func invalidateEpochLocked() {
        if activationEpoch < UInt64.max {
            activationEpoch += 1
        }
    }

    private func replaceViewLocked(
        _ phase: HostAgentBackgroundActivationPhase,
        projection: HostAgentBackgroundProjectionView? = nil
    ) -> HostAgentBackgroundActivationView {
        guard view.generation < UInt64.max - 1 else {
            view = HostAgentBackgroundActivationView(
                generation: UInt64.max,
                phase: .failed(.generationExhausted)
            )
            return view
        }
        view = HostAgentBackgroundActivationView(
            generation: view.generation + 1,
            phase: phase,
            projection: projection
        )
        return view
    }

    private func coherentProjection(
        _ projection: HostAgentBackgroundProjectionView?,
        readiness: HostAgentBackgroundReadinessView
    ) -> HostAgentBackgroundProjectionView? {
        guard let projection,
              projection.generation
                == readiness.runtime.projectionGeneration,
              HostAgentBackgroundRuntimeEvidence(projection: projection)
                == readiness.runtime
        else { return nil }
        return projection
    }

    private func currentCommandContext(
        route: HostAgentBackgroundCommandRoute? = nil
    ) -> CommandContext? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let activationEpoch = activeEpoch,
              let runtime = activeRuntime,
              case .monitoring(let epoch, _) = view.phase,
              epoch == activationEpoch,
              let projectionView = view.projection,
              case .available(let projection) = projectionView.phase
        else { return nil }
        if let route {
            guard route.activationEpoch == activationEpoch,
                  route.projectionGeneration == projectionView.generation,
                  route.reconnectRoute.peerIdentity
                    == projection.peerIdentity
            else { return nil }
        }
        return CommandContext(
            activationEpoch: activationEpoch,
            projectionGeneration: projectionView.generation,
            peerIdentity: projection.peerIdentity,
            projection: projection,
            runtime: runtime
        )
    }

    private func commandContextIsCurrent(_ context: CommandContext) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard activeEpoch == context.activationEpoch,
              sameRuntime(activeRuntime, context.runtime),
              case .monitoring(let epoch, _) = view.phase,
              epoch == context.activationEpoch,
              let projectionView = view.projection,
              projectionView.generation == context.projectionGeneration,
              case .available(let projection) = projectionView.phase
        else { return false }
        return projection.peerIdentity == context.peerIdentity
    }

    private func projectionAllows(
        _ intent: HostAgentXPCCommandIntent,
        projection: HostAgentBackgroundProjection
    ) -> Bool {
        HostAgentBackgroundSessionCommandPolicy.allows(
            intent,
            payload: projection.payload
        )
    }

    private func commandStateMatchesProjection(
        _ commandState: HostAgentXPCCommandIntentOwnerState,
        projection: HostAgentBackgroundProjection
    ) -> Bool {
        switch commandState {
        case .idle:
            return true
        case .pausing(let intent), .awaitingAcceptance(let intent),
             .awaitingResult(let intent), .retryable(let intent):
            return projectionAllows(intent, projection: projection)
        case .invalidated, .cancelled:
            return false
        }
    }

    fileprivate func deliverCommandResult(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        route: HostAgentBackgroundCommandRoute,
        relay: HostAgentBackgroundCommandObserverRelay
    ) {
        deliveryLock.lock()
        let deliveredResult: HostAgentXPCSnapshotClientCommandResult
        if currentCommandContext(route: route) != nil {
            deliveredResult = result
        } else {
            deliveredResult = .cancelled
        }
        relay.deliver(deliveredResult)
        deliveryLock.unlock()
    }

    private func publish(_ publication: HostAgentBackgroundActivationView) {
        observer(publication)
    }

    private func sameRuntime(
        _ lhs: HostAgentBackgroundActivationRuntime?,
        _ rhs: HostAgentBackgroundActivationRuntime
    ) -> Bool {
        guard let lhs else { return false }
        return lhs === rhs
    }

    private func isMonitoring(
        _ phase: HostAgentBackgroundActivationPhase,
        activationEpoch: UInt64
    ) -> Bool {
        guard case .monitoring(let epoch, _) = phase else { return false }
        return epoch == activationEpoch
    }
}

fileprivate final class HostAgentBackgroundCommandObserverRelay:
    @unchecked Sendable
{
    private let lock = NSLock()
    private weak var owner: HostAgentBackgroundActivationOwner?
    private let route: HostAgentBackgroundCommandRoute
    private let observer: HostAgentXPCSnapshotClient.CommandObserver
    private var terminalDelivered = false

    init(
        owner: HostAgentBackgroundActivationOwner,
        route: HostAgentBackgroundCommandRoute,
        observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) {
        self.owner = owner
        self.route = route
        self.observer = observer
    }

    func publish(_ result: HostAgentXPCSnapshotClientCommandResult) {
        guard let owner else {
            deliver(.cancelled)
            return
        }
        owner.deliverCommandResult(result, route: route, relay: self)
    }

    fileprivate func deliver(
        _ result: HostAgentXPCSnapshotClientCommandResult
    ) {
        lock.lock()
        guard !terminalDelivered else {
            lock.unlock()
            return
        }
        if Self.isTerminal(result) { terminalDelivered = true }
        lock.unlock()
        observer(result)
    }

    private static func isTerminal(
        _ result: HostAgentXPCSnapshotClientCommandResult
    ) -> Bool {
        if case .accepted = result { return false }
        return true
    }
}
