import Foundation

package struct HostAgentBackgroundHomeCommandActivationSnapshot:
    Equatable,
    Sendable
{
    package let phase: HostAgentBackgroundActivationPhase
    package let projection: HostAgentBackgroundProjectionView?

    package init(
        phase: HostAgentBackgroundActivationPhase,
        projection: HostAgentBackgroundProjectionView?
    ) {
        self.phase = phase
        self.projection = projection
    }
}

package enum HostAgentBackgroundHomeCommandPresentationFailure:
    Equatable,
    Sendable
{
    case submissionRejected
    case retryRejected
    case invalidResult
    case generationExhausted
}

package struct HostAgentBackgroundHomeCommandPresentationView:
    Equatable,
    Sendable
{
    package let generation: UInt64
    package let command: HostAgentBackgroundHomeCommandPresentation
    package let result: HostAgentBackgroundHomeCommandResultPresentation?
    package let failure:
        HostAgentBackgroundHomeCommandPresentationFailure?

    package init(
        generation: UInt64,
        command: HostAgentBackgroundHomeCommandPresentation,
        result: HostAgentBackgroundHomeCommandResultPresentation?,
        failure: HostAgentBackgroundHomeCommandPresentationFailure?
    ) {
        self.generation = generation
        self.command = command
        self.result = result
        self.failure = failure
    }
}

/// App-side state owner for the pure Home command policy. Construction is
/// inert. Callers explicitly refresh it from one activation sample, then ask
/// it to submit or retry through the same activation owner. No Home/AppKit or
/// legacy Host callback is owned here.
package final class HostAgentBackgroundHomeCommandPresentationOwner:
    @unchecked Sendable
{
    package typealias ActivationSnapshotProvider = @Sendable ()
        -> HostAgentBackgroundHomeCommandActivationSnapshot
    package typealias AvailabilityProvider = @Sendable ()
        -> HostAgentBackgroundCommandAvailability
    package typealias Submit = @Sendable (
        _ route: HostAgentBackgroundCommandRoute,
        _ intent: HostAgentXPCCommandIntent,
        _ observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool
    package typealias Retry = @Sendable (
        _ route: HostAgentBackgroundCommandRoute,
        _ observer: @escaping HostAgentXPCSnapshotClient.CommandObserver
    ) -> Bool
    package typealias CommandIDFactory = @Sendable () -> String
    package typealias Observer = @Sendable
        (HostAgentBackgroundHomeCommandPresentationView) -> Void

    private struct RuntimeSample {
        let activation: HostAgentBackgroundHomeCommandActivationSnapshot
        let command: HostAgentBackgroundHomeCommandPresentation
    }

    private struct Attempt: Equatable {
        let generation: UInt64
        let action: HostAgentBackgroundHomeCommandAction
        let submission: HostAgentBackgroundHomeCommandSubmission
    }

    private struct RoutedResult: Equatable {
        let route: HostAgentBackgroundCommandRoute
        let presentation:
            HostAgentBackgroundHomeCommandResultPresentation
    }

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let observeActivation: ActivationSnapshotProvider
    private let observeAvailability: AvailabilityProvider
    private let submitOperation: Submit
    private let retryOperation: Retry
    private let makeCommandID: CommandIDFactory
    private let observer: Observer

    private var view = HostAgentBackgroundHomeCommandPresentationView(
        generation: 0,
        command: .unavailable,
        result: nil,
        failure: nil
    )
    private var attemptGeneration: UInt64 = 0
    private var transitionInFlight = false
    private var activeAttempt: Attempt?
    private var activeAccepted = false
    private var retrySubmission: HostAgentBackgroundHomeCommandSubmission?
    private var routedResult: RoutedResult?
    private var failedRoute: HostAgentBackgroundCommandRoute?
    private var failure:
        HostAgentBackgroundHomeCommandPresentationFailure?

    package static func makeProduct(
        activationOwner: HostAgentBackgroundActivationOwner,
        observer: @escaping Observer = { _ in }
    ) -> HostAgentBackgroundHomeCommandPresentationOwner {
        HostAgentBackgroundHomeCommandPresentationOwner(
            observeActivation: {
                let activation = activationOwner.snapshot()
                return HostAgentBackgroundHomeCommandActivationSnapshot(
                    phase: activation.phase,
                    projection: activation.projection
                )
            },
            observeAvailability: {
                activationOwner.commandAvailabilitySnapshot()
            },
            submit: { route, intent, commandObserver in
                activationOwner.submitCommand(
                    route: route,
                    intent: intent,
                    observer: commandObserver
                )
            },
            retry: { route, commandObserver in
                activationOwner.retryCommand(
                    route: route,
                    observer: commandObserver
                )
            },
            makeCommandID: { UUID().uuidString.lowercased() },
            observer: observer
        )
    }

    package init(
        observeActivation: @escaping ActivationSnapshotProvider,
        observeAvailability: @escaping AvailabilityProvider,
        submit: @escaping Submit,
        retry: @escaping Retry,
        makeCommandID: @escaping CommandIDFactory,
        observer: @escaping Observer = { _ in }
    ) {
        self.observeActivation = observeActivation
        self.observeAvailability = observeAvailability
        submitOperation = submit
        retryOperation = retry
        self.makeCommandID = makeCommandID
        self.observer = observer
    }

    package func snapshot()
        -> HostAgentBackgroundHomeCommandPresentationView
    {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func refresh() -> Bool {
        deliveryLock.lock()
        let sample = runtimeSample()
        let publication = updateView(with: sample)
        publish(publication)
        deliveryLock.unlock()
        return publication != nil
    }

    @discardableResult
    package func submit(
        _ action: HostAgentBackgroundHomeCommandAction
    ) -> Bool {
        deliveryLock.lock()
        let initialSample = runtimeSample()
        let initialPublication = updateView(with: initialSample)
        publish(initialPublication)

        stateLock.lock()
        guard !transitionInFlight,
              activeAttempt == nil,
              failure == nil
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        transitionInFlight = true
        let command = view.command
        stateLock.unlock()

        guard let submission =
            HostAgentBackgroundHomeCommandPolicy.submission(
                action: action,
                presentation: command,
                makeCommandID: makeCommandID
            )
        else {
            finishTransition()
            deliveryLock.unlock()
            return false
        }
        guard let attempt = beginAttempt(
            action: action,
            submission: submission
        ) else {
            finishTransition()
            let publication = forceGenerationFailure()
            publish(publication)
            deliveryLock.unlock()
            return false
        }

        let accepted = submitOperation(
            submission.route,
            submission.intent,
            { [weak self] result in
                self?.consume(
                    result,
                    attempt: attempt
                )
            }
        )
        let sample = runtimeSample()
        let publication = finishOperation(
            accepted: accepted,
            attempt: attempt,
            rejectedFailure: .submissionRejected,
            sample: sample
        )
        publish(publication)
        deliveryLock.unlock()
        return accepted
    }

    @discardableResult
    package func retry() -> Bool {
        deliveryLock.lock()
        let initialSample = runtimeSample()
        let initialPublication = updateView(with: initialSample)
        publish(initialPublication)

        stateLock.lock()
        guard !transitionInFlight,
              activeAttempt == nil,
              failure == nil,
              let retrySubmission,
              let route = HostAgentBackgroundHomeCommandPolicy.retryRoute(
                presentation: view.command
              ),
              route == retrySubmission.route,
              let action = view.command.activeAction,
              routedResult?.presentation.action == action
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        transitionInFlight = true
        stateLock.unlock()

        guard let attempt = beginAttempt(
            action: action,
            submission: retrySubmission
        ) else {
            finishTransition()
            let publication = forceGenerationFailure()
            publish(publication)
            deliveryLock.unlock()
            return false
        }

        let accepted = retryOperation(
            route,
            { [weak self] result in
                self?.consume(result, attempt: attempt)
            }
        )
        let sample = runtimeSample()
        let publication = finishOperation(
            accepted: accepted,
            attempt: attempt,
            rejectedFailure: .retryRejected,
            sample: sample
        )
        publish(publication)
        deliveryLock.unlock()
        return accepted
    }

    private func runtimeSample() -> RuntimeSample {
        let activation = observeActivation()
        let availability = observeAvailability()
        return RuntimeSample(
            activation: activation,
            command: HostAgentBackgroundHomeCommandPolicy.presentation(
                phase: activation.phase,
                projection: activation.projection,
                availability: availability
            )
        )
    }

    private func beginAttempt(
        action: HostAgentBackgroundHomeCommandAction,
        submission: HostAgentBackgroundHomeCommandSubmission
    ) -> Attempt? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard transitionInFlight,
              activeAttempt == nil,
              attemptGeneration < UInt64.max
        else { return nil }
        attemptGeneration += 1
        let attempt = Attempt(
            generation: attemptGeneration,
            action: action,
            submission: submission
        )
        activeAttempt = attempt
        activeAccepted = false
        retrySubmission = nil
        routedResult = nil
        failedRoute = nil
        failure = nil
        return attempt
    }

    private func finishOperation(
        accepted: Bool,
        attempt: Attempt,
        rejectedFailure:
            HostAgentBackgroundHomeCommandPresentationFailure,
        sample: RuntimeSample
    ) -> HostAgentBackgroundHomeCommandPresentationView? {
        stateLock.lock()
        transitionInFlight = false
        if activeAttempt == attempt {
            if accepted {
                if !attemptIsRepresented(attempt, by: sample) {
                    if routeIsRelevant(
                        attempt.submission.route,
                        in: sample
                    ) {
                        failLocked(
                            route: attempt.submission.route,
                            failure: .invalidResult
                        )
                    } else {
                        clearAttemptLocked(attempt)
                    }
                }
            } else if routeIsRelevant(
                attempt.submission.route,
                in: sample
            ) {
                failLocked(
                    route: attempt.submission.route,
                    failure: rejectedFailure
                )
            } else {
                clearAttemptLocked(attempt)
            }
        } else if !accepted,
                  routeIsRelevant(attempt.submission.route, in: sample)
        {
            failLocked(
                route: attempt.submission.route,
                failure: .invalidResult
            )
        }
        let publication = updateViewLocked(with: sample)
        stateLock.unlock()
        return publication
    }

    private func consume(
        _ result: HostAgentXPCSnapshotClientCommandResult,
        attempt: Attempt
    ) {
        deliveryLock.lock()
        let sample = runtimeSample()
        stateLock.lock()
        guard activeAttempt == attempt else {
            stateLock.unlock()
            deliveryLock.unlock()
            return
        }
        guard routeIsRelevant(attempt.submission.route, in: sample) else {
            clearAttemptLocked(attempt)
            let publication = updateViewLocked(with: sample)
            stateLock.unlock()
            publish(publication)
            deliveryLock.unlock()
            return
        }
        guard let resultPresentation =
            HostAgentBackgroundHomeCommandPolicy.resultPresentation(
                result,
                submission: attempt.submission
            )
        else {
            failLocked(
                route: attempt.submission.route,
                failure: .invalidResult
            )
            let publication = updateViewLocked(with: sample)
            stateLock.unlock()
            publish(publication)
            deliveryLock.unlock()
            return
        }

        switch result {
        case .accepted:
            guard !activeAccepted else {
                failLocked(
                    route: attempt.submission.route,
                    failure: .invalidResult
                )
                let publication = updateViewLocked(with: sample)
                stateLock.unlock()
                publish(publication)
                deliveryLock.unlock()
                return
            }
        case .completed, .resultUnknown, .resultTimedOut:
            guard activeAccepted else {
                failLocked(
                    route: attempt.submission.route,
                    failure: .invalidResult
                )
                let publication = updateViewLocked(with: sample)
                stateLock.unlock()
                publish(publication)
                deliveryLock.unlock()
                return
            }
        case .invalidRequest, .invalidResponse, .disconnected,
             .acceptanceTimedOut, .cancelled, .invalidState:
            break
        }

        let stateIsValid: Bool
        switch result {
        case .accepted:
            stateIsValid = sample.command.route
                == attempt.submission.route
                && sample.command.activeAction == attempt.action
                && sample.command.isBusy
                && !sample.command.canRetry
        case .resultUnknown, .resultTimedOut:
            stateIsValid = resultPresentation.canRetry
                && sample.command.route == attempt.submission.route
                && sample.command.activeAction == attempt.action
                && sample.command.canRetry
                && HostAgentBackgroundHomeCommandPolicy.retryRoute(
                    presentation: sample.command
                ) == attempt.submission.route
        case .completed, .invalidRequest:
            stateIsValid = resultPresentation.isTerminal
                && !resultPresentation.canRetry
                && sample.command.route == attempt.submission.route
                && sample.command.activeAction == nil
                && !sample.command.isBusy
                && !sample.command.canRetry
        case .invalidResponse, .disconnected, .acceptanceTimedOut,
             .cancelled, .invalidState:
            stateIsValid = resultPresentation.isTerminal
                && !resultPresentation.canRetry
                && sample.command == .unavailable
        }
        guard stateIsValid else {
            failLocked(
                route: attempt.submission.route,
                failure: .invalidResult
            )
            let publication = updateViewLocked(with: sample)
            stateLock.unlock()
            publish(publication)
            deliveryLock.unlock()
            return
        }

        routedResult = RoutedResult(
            route: attempt.submission.route,
            presentation: resultPresentation
        )
        if case .accepted = result { activeAccepted = true }
        if resultPresentation.isTerminal {
            activeAttempt = nil
            activeAccepted = false
            retrySubmission = resultPresentation.canRetry
                ? attempt.submission
                : nil
        }
        let publication = updateViewLocked(with: sample)
        stateLock.unlock()
        publish(publication)
        deliveryLock.unlock()
    }

    private func updateView(
        with sample: RuntimeSample
    ) -> HostAgentBackgroundHomeCommandPresentationView? {
        stateLock.lock()
        let publication = updateViewLocked(with: sample)
        stateLock.unlock()
        return publication
    }

    private func updateViewLocked(
        with sample: RuntimeSample
    ) -> HostAgentBackgroundHomeCommandPresentationView? {
        if let activeAttempt,
           !routeIsRelevant(activeAttempt.submission.route, in: sample)
        {
            clearAttemptLocked(activeAttempt)
        }
        if let retrySubmission,
           sample.command.route != retrySubmission.route
            || !sample.command.canRetry
            || sample.command.activeAction == nil
            || sample.command.activeAction
                != routedResult?.presentation.action
        {
            self.retrySubmission = nil
            if routedResult?.presentation.canRetry == true {
                routedResult = nil
            }
        }
        if let routedResult,
           !routeIsRelevant(routedResult.route, in: sample)
        {
            self.routedResult = nil
        }
        if let failedRoute,
           !routeIsRelevant(failedRoute, in: sample)
        {
            self.failedRoute = nil
            failure = nil
        }

        let command = failedRoute != nil ? .unavailable : sample.command
        let result = routedResult?.presentation
        if view.command == command,
           view.result == result,
           view.failure == failure
        {
            return nil
        }
        return replaceViewLocked(
            command: command,
            result: result,
            failure: failure
        )
    }

    private func replaceViewLocked(
        command: HostAgentBackgroundHomeCommandPresentation,
        result: HostAgentBackgroundHomeCommandResultPresentation?,
        failure:
            HostAgentBackgroundHomeCommandPresentationFailure?
    ) -> HostAgentBackgroundHomeCommandPresentationView? {
        if view.generation == UInt64.max {
            activeAttempt = nil
            activeAccepted = false
            retrySubmission = nil
            routedResult = nil
            failedRoute = nil
            self.failure = .generationExhausted
            let failed = HostAgentBackgroundHomeCommandPresentationView(
                generation: UInt64.max,
                command: .unavailable,
                result: nil,
                failure: .generationExhausted
            )
            guard view != failed else { return nil }
            view = failed
            return failed
        }
        view = HostAgentBackgroundHomeCommandPresentationView(
            generation: view.generation + 1,
            command: command,
            result: result,
            failure: failure
        )
        return view
    }

    private func forceGenerationFailure()
        -> HostAgentBackgroundHomeCommandPresentationView?
    {
        stateLock.lock()
        transitionInFlight = false
        activeAttempt = nil
        activeAccepted = false
        retrySubmission = nil
        routedResult = nil
        failedRoute = nil
        failure = .generationExhausted
        let publication = replaceViewLocked(
            command: .unavailable,
            result: nil,
            failure: .generationExhausted
        )
        stateLock.unlock()
        return publication
    }

    private func attemptIsRepresented(
        _ attempt: Attempt,
        by sample: RuntimeSample
    ) -> Bool {
        sample.command.route == attempt.submission.route
            && sample.command.activeAction == attempt.action
            && sample.command.isBusy
            && !sample.command.canRetry
    }

    private func routeIsRelevant(
        _ route: HostAgentBackgroundCommandRoute,
        in sample: RuntimeSample
    ) -> Bool {
        if sample.command.route == route { return true }
        guard case .monitoring(let epoch, _) = sample.activation.phase,
              epoch == route.activationEpoch,
              let projection = sample.activation.projection,
              projection.generation == route.projectionGeneration,
              case .available(let available) = projection.phase
        else { return false }
        return available.peerIdentity
            == route.reconnectRoute.peerIdentity
    }

    private func clearAttemptLocked(_ attempt: Attempt) {
        guard activeAttempt == attempt else { return }
        activeAttempt = nil
        activeAccepted = false
        if retrySubmission?.route == attempt.submission.route {
            retrySubmission = nil
        }
        if routedResult?.route == attempt.submission.route {
            routedResult = nil
        }
    }

    private func failLocked(
        route: HostAgentBackgroundCommandRoute,
        failure: HostAgentBackgroundHomeCommandPresentationFailure
    ) {
        activeAttempt = nil
        activeAccepted = false
        retrySubmission = nil
        routedResult = nil
        failedRoute = route
        self.failure = failure
    }

    private func finishTransition() {
        stateLock.lock()
        transitionInFlight = false
        stateLock.unlock()
    }

    private func publish(
        _ publication: HostAgentBackgroundHomeCommandPresentationView?
    ) {
        if let publication { observer(publication) }
    }
}
