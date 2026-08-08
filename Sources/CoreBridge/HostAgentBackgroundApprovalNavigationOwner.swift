import Foundation
import ServiceManagement

package enum HostAgentBackgroundApprovalNavigationIntent:
    Equatable,
    Sendable
{
    case openLoginItemsAfterUserConfirmation
}

package enum HostAgentBackgroundApprovalNavigationFailure:
    Equatable,
    Sendable
{
    case serviceUnavailable
    case generationExhausted
}

package enum HostAgentBackgroundApprovalNavigationPhase:
    Equatable,
    Sendable
{
    case idle
    case checking
    case notRequired
    case navigationRequested
    case failed(HostAgentBackgroundApprovalNavigationFailure)
}

package struct HostAgentBackgroundApprovalNavigationView:
    Equatable,
    Sendable
{
    package let generation: UInt64
    package let phase: HostAgentBackgroundApprovalNavigationPhase
    package let registration: HostAgentBackgroundRegistrationStatus?

    package init(
        generation: UInt64,
        phase: HostAgentBackgroundApprovalNavigationPhase,
        registration: HostAgentBackgroundRegistrationStatus?
    ) {
        self.generation = generation
        self.phase = phase
        self.registration = registration
    }
}

/// Owns only the user-confirmed transition to the Login Items settings panel.
/// Construction and registration observation are inert until the explicit
/// typed intent arrives. The owner rechecks authoritative registration state
/// and opens settings only while approval is still required; requesting
/// navigation never represents approval, registration, activation or ready.
package final class HostAgentBackgroundApprovalNavigationOwner:
    @unchecked Sendable
{
    package typealias Observer = @Sendable
        (HostAgentBackgroundApprovalNavigationView) -> Void
    package typealias RegistrationObservation = @Sendable ()
        -> HostAgentBackgroundRegistrationStatus
    package typealias LoginItemsNavigation = @Sendable () -> Void

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let observeRegistration: RegistrationObservation
    private let openLoginItems: LoginItemsNavigation
    private let observer: Observer
    private var navigationInFlight = false
    private var view = HostAgentBackgroundApprovalNavigationView(
        generation: 0,
        phase: .idle,
        registration: nil
    )

    package static func makeProduct(
        observer: @escaping Observer = { _ in }
    ) -> HostAgentBackgroundApprovalNavigationOwner {
        HostAgentBackgroundApprovalNavigationOwner(
            observeRegistration: {
                HostAgentBackgroundServiceObserver
                    .observeRegistrationStatus()
            },
            openLoginItems: {
                SMAppService.openSystemSettingsLoginItems()
            },
            observer: observer
        )
    }

    package init(
        observeRegistration: @escaping RegistrationObservation,
        openLoginItems: @escaping LoginItemsNavigation,
        observer: @escaping Observer = { _ in }
    ) {
        self.observeRegistration = observeRegistration
        self.openLoginItems = openLoginItems
        self.observer = observer
    }

    package func snapshot() -> HostAgentBackgroundApprovalNavigationView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func apply(
        _ intent: HostAgentBackgroundApprovalNavigationIntent
    ) -> Bool {
        guard begin(intent) else { return false }

        let registration = observeRegistration()
        switch registration {
        case .requiresApproval:
            openLoginItems()
            return finish(
                phase: .navigationRequested,
                registration: registration,
                succeeded: true
            )
        case .notRegistered, .enabled:
            return finish(
                phase: .notRequired,
                registration: registration,
                succeeded: false
            )
        case .serviceUnavailable:
            return finish(
                phase: .failed(.serviceUnavailable),
                registration: registration,
                succeeded: false
            )
        }
    }

    private func begin(
        _ intent: HostAgentBackgroundApprovalNavigationIntent
    ) -> Bool {
        switch intent {
        case .openLoginItemsAfterUserConfirmation:
            break
        }

        deliveryLock.lock()
        stateLock.lock()
        guard !navigationInFlight,
              view.generation < UInt64.max
        else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }
        navigationInFlight = true
        view = HostAgentBackgroundApprovalNavigationView(
            generation: view.generation + 1,
            phase: .checking,
            registration: nil
        )
        let publication = view
        stateLock.unlock()
        observer(publication)
        deliveryLock.unlock()
        return true
    }

    private func finish(
        phase: HostAgentBackgroundApprovalNavigationPhase,
        registration: HostAgentBackgroundRegistrationStatus,
        succeeded: Bool
    ) -> Bool {
        deliveryLock.lock()
        stateLock.lock()
        guard navigationInFlight else {
            stateLock.unlock()
            deliveryLock.unlock()
            return false
        }

        let finalPhase: HostAgentBackgroundApprovalNavigationPhase
        let finalResult: Bool
        if view.generation == UInt64.max {
            finalPhase = .failed(.generationExhausted)
            finalResult = false
        } else {
            finalPhase = phase
            finalResult = succeeded
        }
        view = HostAgentBackgroundApprovalNavigationView(
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
        navigationInFlight = false
        stateLock.unlock()
        deliveryLock.unlock()
        return finalResult
    }
}
