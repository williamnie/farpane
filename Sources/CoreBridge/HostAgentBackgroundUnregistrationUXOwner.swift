import Foundation

package enum HostAgentBackgroundUnregistrationUXIntent:
    Equatable,
    Sendable
{
    case requestBackgroundUnregistration
    case confirmBackgroundUnregistration
    case cancelBackgroundUnregistration
}

package struct HostAgentBackgroundUnregistrationUXPrompt:
    Equatable,
    Sendable
{
    package let title: String
    package let message: String
    package let confirmButtonTitle: String
    package let cancelButtonTitle: String

    fileprivate init(
        title: String,
        message: String,
        confirmButtonTitle: String,
        cancelButtonTitle: String
    ) {
        self.title = title
        self.message = message
        self.confirmButtonTitle = confirmButtonTitle
        self.cancelButtonTitle = cancelButtonTitle
    }
}

package enum HostAgentBackgroundUnregistrationUXFailure:
    Equatable,
    Sendable
{
    case mutation(HostAgentBackgroundRegistrationMutationFailure)
    case invalidMutationResult
    case generationExhausted
}

package enum HostAgentBackgroundUnregistrationUXPhase:
    Equatable,
    Sendable
{
    case idle
    case awaitingConfirmation(HostAgentBackgroundUnregistrationUXPrompt)
    case unregistering
    case unregistered
    case cancelled
    case failed(HostAgentBackgroundUnregistrationUXFailure)
}

package struct HostAgentBackgroundUnregistrationUXView:
    Equatable,
    Sendable
{
    package let generation: UInt64
    package let phase: HostAgentBackgroundUnregistrationUXPhase
    package let registration: HostAgentBackgroundRegistrationStatus?

    package init(
        generation: UInt64,
        phase: HostAgentBackgroundUnregistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) {
        self.generation = generation
        self.phase = phase
        self.registration = registration
    }
}

/// Product-independent confirmation and result validation for stopping and
/// unregistering the background Agent. The caller must supply the same
/// mutation authority used for registration so opposing operations cannot
/// reach ServiceManagement concurrently through separate owners.
package final class HostAgentBackgroundUnregistrationUXOwner:
    @unchecked Sendable
{
    package typealias UnregistrationOperation = @Sendable () -> (
        Bool,
        HostAgentBackgroundRegistrationMutationView
    )
    package typealias Observer = @Sendable
        (HostAgentBackgroundUnregistrationUXView) -> Void

    private static let confirmationPrompt =
        HostAgentBackgroundUnregistrationUXPrompt(
            title: "关闭后台连接？",
            message: "关闭后，FarPane 将停止后台组件并不再接受新的远程连接。设备身份和服务器配置会保留，之后可以重新启用。",
            confirmButtonTitle: "关闭后台连接",
            cancelButtonTitle: "取消"
        )

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let performUnregistration: UnregistrationOperation
    private let observer: Observer
    private var transitionInFlight = false
    private var view = HostAgentBackgroundUnregistrationUXView(
        generation: 0,
        phase: .idle,
        registration: nil
    )

    package static func makeProduct(
        mutationOwner: HostAgentBackgroundRegistrationMutationOwner,
        observer: @escaping Observer = { _ in }
    ) -> HostAgentBackgroundUnregistrationUXOwner {
        HostAgentBackgroundUnregistrationUXOwner(
            performUnregistration: {
                let accepted = mutationOwner.apply(
                    .unregisterBackgroundAgent
                )
                return (accepted, mutationOwner.snapshot())
            },
            observer: observer
        )
    }

    package init(
        performUnregistration: @escaping UnregistrationOperation,
        observer: @escaping Observer = { _ in }
    ) {
        self.performUnregistration = performUnregistration
        self.observer = observer
    }

    package func snapshot() -> HostAgentBackgroundUnregistrationUXView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func apply(
        _ intent: HostAgentBackgroundUnregistrationUXIntent
    ) -> Bool {
        switch intent {
        case .requestBackgroundUnregistration:
            return requestUnregistration()
        case .confirmBackgroundUnregistration:
            return confirmUnregistration()
        case .cancelBackgroundUnregistration:
            return cancelUnregistration()
        }
    }

    private func requestUnregistration() -> Bool {
        transition(
            allowed: { phase in
                switch phase {
                case .idle, .unregistered, .cancelled, .failed:
                    return true
                case .awaitingConfirmation, .unregistering:
                    return false
                }
            },
            phase: .awaitingConfirmation(Self.confirmationPrompt),
            registration: nil
        )
    }

    private func cancelUnregistration() -> Bool {
        transition(
            allowed: { phase in
                if case .awaitingConfirmation = phase { return true }
                return false
            },
            phase: .cancelled,
            registration: currentRegistration()
        )
    }

    private func confirmUnregistration() -> Bool {
        guard beginOperation() else { return false }
        let (accepted, mutation) = performUnregistration()
        let resolution = resolve(accepted: accepted, mutation: mutation)
        return finishOperation(
            phase: resolution.phase,
            registration: mutation.registration,
            result: resolution.result
        )
    }

    private func transition(
        allowed: (HostAgentBackgroundUnregistrationUXPhase) -> Bool,
        phase: HostAgentBackgroundUnregistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard !transitionInFlight,
              view.generation < UInt64.max,
              allowed(view.phase)
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        transitionInFlight = true
        replaceViewLocked(phase: phase, registration: registration)
        let publication = view
        stateLock.unlock()
        observer(publication)
        stateLock.lock()
        transitionInFlight = false
        stateLock.unlock()
        deliveryLock.unlock()
        return true
    }

    private func beginOperation() -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard !transitionInFlight,
              view.generation < UInt64.max,
              case .awaitingConfirmation = view.phase
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        transitionInFlight = true
        replaceViewLocked(
            phase: .unregistering,
            registration: view.registration
        )
        let publication = view
        stateLock.unlock()
        observer(publication)
        deliveryLock.unlock()
        return true
    }

    private func finishOperation(
        phase: HostAgentBackgroundUnregistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?,
        result: Bool
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard transitionInFlight else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }

        let finalResult: Bool
        if view.generation == UInt64.max {
            replaceViewLocked(
                phase: .failed(.generationExhausted),
                registration: registration
            )
            finalResult = false
        } else {
            replaceViewLocked(phase: phase, registration: registration)
            finalResult = result
        }
        let publication = view
        stateLock.unlock()
        observer(publication)
        stateLock.lock()
        transitionInFlight = false
        stateLock.unlock()
        deliveryLock.unlock()
        return finalResult
    }

    private func resolve(
        accepted: Bool,
        mutation: HostAgentBackgroundRegistrationMutationView
    ) -> (phase: HostAgentBackgroundUnregistrationUXPhase, result: Bool) {
        switch mutation.phase {
        case .unregistered
            where accepted && mutation.registration == .notRegistered:
            return (.unregistered, true)
        case .failed(let intent, let failure)
            where !accepted && intent == .unregisterBackgroundAgent:
            return (.failed(.mutation(failure)), false)
        case .idle, .registering, .unregistering, .registered,
             .requiresApproval, .unregistered, .failed:
            return (.failed(.invalidMutationResult), false)
        }
    }

    private func replaceViewLocked(
        phase: HostAgentBackgroundUnregistrationUXPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) {
        view = HostAgentBackgroundUnregistrationUXView(
            generation: view.generation == UInt64.max
                ? UInt64.max
                : view.generation + 1,
            phase: phase,
            registration: registration
        )
    }

    private func currentRegistration()
        -> HostAgentBackgroundRegistrationStatus?
    {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view.registration
    }
}
