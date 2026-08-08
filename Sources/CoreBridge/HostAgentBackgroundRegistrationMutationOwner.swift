import Foundation
import ServiceManagement

package enum HostAgentBackgroundRegistrationMutationIntent:
    Equatable,
    Sendable
{
    case registerBackgroundAgent
    case unregisterBackgroundAgent
}

package enum HostAgentBackgroundRegistrationMutationFailure:
    Equatable,
    Sendable
{
    case invalidLaunchAgent
    case invalidApplication
    case invalidCodeSignature
    case distributionNotarizationRequired
    case serviceUnavailable
    case registrationNotEffective
    case unregistrationNotEffective
    case generationExhausted
}

package enum HostAgentBackgroundRegistrationMutationPhase:
    Equatable,
    Sendable
{
    case idle
    case registering
    case unregistering
    case registered
    case requiresApproval
    case unregistered
    case failed(
        intent: HostAgentBackgroundRegistrationMutationIntent,
        failure: HostAgentBackgroundRegistrationMutationFailure
    )
}

package struct HostAgentBackgroundRegistrationMutationView:
    Equatable,
    Sendable
{
    package let generation: UInt64
    package let phase: HostAgentBackgroundRegistrationMutationPhase
    package let registration: HostAgentBackgroundRegistrationStatus?

    package init(
        generation: UInt64,
        phase: HostAgentBackgroundRegistrationMutationPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) {
        self.generation = generation
        self.phase = phase
        self.registration = registration
    }
}

/// The sole owner of App-side ServiceManagement mutations. Construction is
/// inert: only an explicit typed intent can reach register or unregister.
/// Registration re-runs the fixed signed-asset identity gate immediately
/// before mutation. A mutation call returning is never considered readiness;
/// the service's post-operation status remains authoritative.
package final class HostAgentBackgroundRegistrationMutationOwner:
    @unchecked Sendable
{
    package typealias Observer = @Sendable
        (HostAgentBackgroundRegistrationMutationView) -> Void
    package typealias IdentityAssessment = @Sendable ()
        -> HostAgentRegistrationIdentityStatus
    package typealias Mutation = @Sendable () throws -> Void
    package typealias RegistrationObservation = @Sendable ()
        -> HostAgentBackgroundRegistrationStatus

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let assessIdentity: IdentityAssessment
    private let registerService: Mutation
    private let unregisterService: Mutation
    private let observeRegistration: RegistrationObservation
    private let observer: Observer
    private var mutationInFlight = false
    private var view = HostAgentBackgroundRegistrationMutationView(
        generation: 0,
        phase: .idle,
        registration: nil
    )

    package static func makeProduct(
        observer: @escaping Observer = { _ in }
    ) -> HostAgentBackgroundRegistrationMutationOwner {
        HostAgentBackgroundRegistrationMutationOwner(
            assessIdentity: {
                HostAgentRegistrationIdentityGate.assessMainBundle()
            },
            register: {
                let service = SMAppService.agent(
                    plistName: HostAgentBackgroundServiceObserver.plistName
                )
                try service.register()
            },
            unregister: {
                let service = SMAppService.agent(
                    plistName: HostAgentBackgroundServiceObserver.plistName
                )
                try service.unregister()
            },
            observeRegistration: {
                let service = SMAppService.agent(
                    plistName: HostAgentBackgroundServiceObserver.plistName
                )
                return HostAgentSMAppServiceStatusAdapter.map(service.status)
            },
            observer: observer
        )
    }

    package init(
        assessIdentity: @escaping IdentityAssessment,
        register: @escaping Mutation,
        unregister: @escaping Mutation,
        observeRegistration: @escaping RegistrationObservation,
        observer: @escaping Observer = { _ in }
    ) {
        self.assessIdentity = assessIdentity
        registerService = register
        unregisterService = unregister
        self.observeRegistration = observeRegistration
        self.observer = observer
    }

    package func snapshot() -> HostAgentBackgroundRegistrationMutationView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func apply(
        _ intent: HostAgentBackgroundRegistrationMutationIntent
    ) -> Bool {
        guard begin(intent) else { return false }

        switch intent {
        case .registerBackgroundAgent:
            if let failure = registrationPreflightFailure(
                assessIdentity()
            ) {
                return finish(
                    intent: intent,
                    phase: .failed(intent: intent, failure: failure),
                    registration: nil,
                    succeeded: false
                )
            }
            _ = try? registerService()
        case .unregisterBackgroundAgent:
            // Unregistration is the recovery path and must remain available
            // even when the current App no longer passes registration gates.
            _ = try? unregisterService()
        }

        let registration = observeRegistration()
        let resolution = resolve(intent, registration: registration)
        return finish(
            intent: intent,
            phase: resolution.phase,
            registration: registration,
            succeeded: resolution.succeeded
        )
    }

    private func begin(
        _ intent: HostAgentBackgroundRegistrationMutationIntent
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard !mutationInFlight,
              view.generation < UInt64.max
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        mutationInFlight = true
        view = HostAgentBackgroundRegistrationMutationView(
            generation: view.generation + 1,
            phase: intent == .registerBackgroundAgent
                ? .registering
                : .unregistering,
            registration: nil
        )
        let publication = view
        stateLock.unlock()
        observer(publication)
        deliveryLock.unlock()
        return true
    }

    private func finish(
        intent: HostAgentBackgroundRegistrationMutationIntent,
        phase: HostAgentBackgroundRegistrationMutationPhase,
        registration: HostAgentBackgroundRegistrationStatus?,
        succeeded: Bool
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard mutationInFlight else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }

        let finalPhase: HostAgentBackgroundRegistrationMutationPhase
        let finalResult: Bool
        if view.generation == UInt64.max {
            finalPhase = .failed(
                intent: intent,
                failure: .generationExhausted
            )
            finalResult = false
        } else {
            finalPhase = phase
            finalResult = succeeded
        }
        view = HostAgentBackgroundRegistrationMutationView(
            generation: view.generation == UInt64.max
                ? UInt64.max
                : view.generation + 1,
            phase: finalPhase,
            registration: registration
        )
        let publication = view
        stateLock.unlock()
        observer(publication)
        stateLock.lock()
        mutationInFlight = false
        stateLock.unlock()
        deliveryLock.unlock()
        return finalResult
    }

    private func registrationPreflightFailure(
        _ status: HostAgentRegistrationIdentityStatus
    ) -> HostAgentBackgroundRegistrationMutationFailure? {
        switch status {
        case .invalidLaunchAgent:
            return .invalidLaunchAgent
        case .invalidApplication:
            return .invalidApplication
        case .invalidCodeSignature:
            return .invalidCodeSignature
        case .distributionNotarizationRequired:
            return .distributionNotarizationRequired
        case .localDevelopmentEligible:
            return nil
        }
    }

    private func resolve(
        _ intent: HostAgentBackgroundRegistrationMutationIntent,
        registration: HostAgentBackgroundRegistrationStatus
    ) -> (phase: HostAgentBackgroundRegistrationMutationPhase,
          succeeded: Bool) {
        switch (intent, registration) {
        case (.registerBackgroundAgent, .enabled):
            return (.registered, true)
        case (.registerBackgroundAgent, .requiresApproval):
            return (.requiresApproval, true)
        case (.registerBackgroundAgent, .serviceUnavailable),
             (.unregisterBackgroundAgent, .serviceUnavailable):
            return (
                .failed(intent: intent, failure: .serviceUnavailable),
                false
            )
        case (.registerBackgroundAgent, .notRegistered):
            return (
                .failed(
                    intent: intent,
                    failure: .registrationNotEffective
                ),
                false
            )
        case (.unregisterBackgroundAgent, .notRegistered):
            return (.unregistered, true)
        case (.unregisterBackgroundAgent, .enabled),
             (.unregisterBackgroundAgent, .requiresApproval):
            return (
                .failed(
                    intent: intent,
                    failure: .unregistrationNotEffective
                ),
                false
            )
        }
    }
}
