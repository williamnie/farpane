import Foundation

package struct HostAgentBackgroundRuntimeEvidence: Equatable, Sendable {
    package let projectionGeneration: UInt64
    package let handshake: HostAgentBackgroundHandshakeStatus
    package let snapshot: HostAgentBackgroundSnapshotStatus
    package let rendezvous: HostAgentBackgroundRendezvousStatus

    package init(
        projectionGeneration: UInt64,
        handshake: HostAgentBackgroundHandshakeStatus,
        snapshot: HostAgentBackgroundSnapshotStatus,
        rendezvous: HostAgentBackgroundRendezvousStatus
    ) {
        self.projectionGeneration = projectionGeneration
        self.handshake = handshake
        self.snapshot = snapshot
        self.rendezvous = rendezvous
    }

    package init(projection: HostAgentBackgroundProjectionView) {
        self.init(
            projectionGeneration: projection.generation,
            handshake: projection.handshakeStatus,
            snapshot: projection.snapshotStatus,
            rendezvous: projection.rendezvousStatus
        )
    }

    fileprivate var isConsistent: Bool {
        switch handshake {
        case .disconnected:
            return snapshot == .unavailable
                && rendezvous != .registered
        case .incompatible:
            return snapshot == .unavailable
                && rendezvous == .offline
        case .compatible:
            if snapshot == .unavailable {
                return rendezvous != .registered
            }
            return true
        }
    }

    fileprivate static func failClosed(
        projectionGeneration: UInt64
    ) -> HostAgentBackgroundRuntimeEvidence {
        HostAgentBackgroundRuntimeEvidence(
            projectionGeneration: projectionGeneration,
            handshake: .disconnected,
            snapshot: .unavailable,
            rendezvous: .offline
        )
    }
}

package enum HostAgentBackgroundHealthFailure: Equatable, Sendable {
    case invalidRuntimeEvidence
    case generationExhausted
}

package struct HostAgentBackgroundReadinessView: Equatable, Sendable {
    package let generation: UInt64
    package let registration: HostAgentBackgroundRegistrationStatus
    package let runtime: HostAgentBackgroundRuntimeEvidence
    package let failure: HostAgentBackgroundHealthFailure?

    fileprivate init(
        generation: UInt64,
        registration: HostAgentBackgroundRegistrationStatus,
        runtime: HostAgentBackgroundRuntimeEvidence,
        failure: HostAgentBackgroundHealthFailure?
    ) {
        self.generation = generation
        self.registration = registration
        self.runtime = runtime
        self.failure = failure
    }

    package var componentHealth: HostAgentBackgroundComponentHealth {
        HostAgentBackgroundComponentHealth(
            registration: registration,
            handshake: runtime.handshake,
            snapshot: runtime.snapshot,
            rendezvous: runtime.rendezvous
        )
    }

    package var availability: HostAgentBackgroundAvailability {
        guard failure == nil else { return .runtimeEvidenceInvalid }
        return componentHealth.availability
    }

    package var isReady: Bool { availability == .ready }
}

/// App-owned authority for the single background readiness snapshot. It only
/// combines read-only registration observation with evidence derived from the
/// reconnect owner's projection authority. Activation remains a caller policy.
package final class HostAgentBackgroundHealthAuthority: @unchecked Sendable {
    package typealias RegistrationObserver = @Sendable ()
        -> HostAgentBackgroundRegistrationStatus
    package typealias Observer = @Sendable
        (HostAgentBackgroundReadinessView) -> Void

    private let stateLock = NSLock()
    private let deliveryLock = NSRecursiveLock()
    private let observeRegistration: RegistrationObserver
    private let observer: Observer
    private var view: HostAgentBackgroundReadinessView

    package init(
        initialRegistration: HostAgentBackgroundRegistrationStatus,
        observeRegistration: @escaping RegistrationObserver,
        observer: @escaping Observer = { _ in }
    ) {
        self.observeRegistration = observeRegistration
        self.observer = observer
        view = HostAgentBackgroundReadinessView(
            generation: 0,
            registration: initialRegistration,
            runtime: HostAgentBackgroundRuntimeEvidence(
                projectionGeneration: 0,
                handshake: .disconnected,
                snapshot: .unavailable,
                rendezvous: .checking
            ),
            failure: nil
        )
    }

    package func snapshot() -> HostAgentBackgroundReadinessView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    /// Performs exactly one read-only ServiceManagement observation. It never
    /// starts, registers, unregisters or opens settings for the service.
    package func refreshRegistration() {
        stateLock.lock()
        let canRefresh = view.failure == nil
        stateLock.unlock()
        guard canRefresh else { return }

        deliveryLock.lock()
        let registration = observeRegistration()
        let publication = mutateView { current in
            guard current.failure == nil,
                  current.registration != registration
            else { return nil }
            return nextView(
                current: current,
                registration: registration,
                runtime: current.runtime,
                failure: nil
            )
        }
        publish(publication)
        deliveryLock.unlock()
    }

    package func acceptProjection(
        _ projection: HostAgentBackgroundProjectionView
    ) {
        acceptRuntimeEvidence(
            HostAgentBackgroundRuntimeEvidence(projection: projection)
        )
    }

    package func acceptRuntimeEvidence(
        _ evidence: HostAgentBackgroundRuntimeEvidence
    ) {
        deliveryLock.lock()
        let publication = mutateView { current in
            guard current.failure == nil else { return nil }
            guard evidence.isConsistent else {
                return failedView(current: current, evidence: evidence)
            }
            if evidence.projectionGeneration <
                current.runtime.projectionGeneration
            {
                return nil
            }
            if evidence.projectionGeneration ==
                current.runtime.projectionGeneration
            {
                guard evidence != current.runtime else { return nil }
                return failedView(current: current, evidence: evidence)
            }
            return nextView(
                current: current,
                registration: current.registration,
                runtime: evidence,
                failure: nil
            )
        }
        publish(publication)
        deliveryLock.unlock()
    }

    private func mutateView(
        _ mutation: (HostAgentBackgroundReadinessView)
            -> HostAgentBackgroundReadinessView?
    ) -> HostAgentBackgroundReadinessView? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let publication = mutation(view) else { return nil }
        view = publication
        return publication
    }

    private func publish(
        _ publication: HostAgentBackgroundReadinessView?
    ) {
        guard let publication else { return }
        observer(publication)
    }

    private func failedView(
        current: HostAgentBackgroundReadinessView,
        evidence: HostAgentBackgroundRuntimeEvidence
    ) -> HostAgentBackgroundReadinessView {
        nextView(
            current: current,
            registration: current.registration,
            runtime: .failClosed(projectionGeneration: max(
                current.runtime.projectionGeneration,
                evidence.projectionGeneration
            )),
            failure: .invalidRuntimeEvidence
        )
    }

    private func nextView(
        current: HostAgentBackgroundReadinessView,
        registration: HostAgentBackgroundRegistrationStatus,
        runtime: HostAgentBackgroundRuntimeEvidence,
        failure: HostAgentBackgroundHealthFailure?
    ) -> HostAgentBackgroundReadinessView {
        guard current.generation < UInt64.max - 1 else {
            return HostAgentBackgroundReadinessView(
                generation: UInt64.max,
                registration: registration,
                runtime: .failClosed(
                    projectionGeneration: runtime.projectionGeneration
                ),
                failure: .generationExhausted
            )
        }
        return HostAgentBackgroundReadinessView(
            generation: current.generation + 1,
            registration: registration,
            runtime: runtime,
            failure: failure
        )
    }
}

/// Product wiring for the three App-side owners. Construction performs one
/// read-only registration observation but deliberately does not start XPC.
package final class HostAgentBackgroundRuntimeComposition:
    @unchecked Sendable
{
    package let healthAuthority: HostAgentBackgroundHealthAuthority
    package let projectionAuthority: HostAgentBackgroundProjectionAuthority
    package let reconnectOwner: HostAgentXPCReconnectOwner

    private init(
        healthAuthority: HostAgentBackgroundHealthAuthority,
        projectionAuthority: HostAgentBackgroundProjectionAuthority,
        reconnectOwner: HostAgentXPCReconnectOwner
    ) {
        self.healthAuthority = healthAuthority
        self.projectionAuthority = projectionAuthority
        self.reconnectOwner = reconnectOwner
    }

    package static func makeProduct(
        observer: @escaping HostAgentBackgroundHealthAuthority.Observer = {
            _ in
        }
    ) -> HostAgentBackgroundRuntimeComposition {
        let initialRegistration =
            HostAgentBackgroundServiceObserver.observeRegistrationStatus()
        let healthAuthority = HostAgentBackgroundHealthAuthority(
            initialRegistration: initialRegistration,
            observeRegistration: {
                HostAgentBackgroundServiceObserver.observeRegistrationStatus()
            },
            observer: observer
        )
        let projectionAuthority = HostAgentBackgroundProjectionAuthority(
            observer: { [weak healthAuthority] projection in
                healthAuthority?.acceptProjection(projection)
            }
        )
        let reconnectOwner = HostAgentXPCReconnectOwner.makeProduct(
            projectionAuthority: projectionAuthority
        )
        return HostAgentBackgroundRuntimeComposition(
            healthAuthority: healthAuthority,
            projectionAuthority: projectionAuthority,
            reconnectOwner: reconnectOwner
        )
    }

    package func refreshRegistration() {
        healthAuthority.refreshRegistration()
    }
}
