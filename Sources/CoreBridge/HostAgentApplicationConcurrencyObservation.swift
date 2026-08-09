import Foundation

package struct HostAgentApplicationConcurrencyObservation:
    Equatable, Sendable
{
    package let state: HostAgentConcurrencyRuntimeState
    package let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
    package let configRevision: UInt64
    package let sourceGeneration: UInt64
}

package struct HostAgentApplicationConcurrencyObservationStateView:
    Equatable, Sendable
{
    package let acceptedSamples: UInt64
    package let emittedObservations: UInt64
    package let lastSourceGeneration: UInt64
    package let scopeBound: Bool
    package let failed: Bool
}

/// App-process bridge from validated background projection state to the
/// lifecycle evidence owner. It retains only the accepted five-field peer
/// identity and positive configuration revision, never snapshot payloads.
package final class HostAgentApplicationConcurrencyObservationState:
    @unchecked Sendable
{
    private struct Scope: Equatable {
        let peerIdentity: HostAgentXPCSnapshotClientPeerIdentity
        let configRevision: UInt64
    }

    private enum Candidate: Equatable {
        case coherent(
            scope: Scope,
            state: HostAgentConcurrencyRuntimeState
        )
        case transportUnavailable
        case evidenceUnavailable
    }

    private let lock = NSLock()
    private var lastSourceToken: UInt64 = 0
    private var lastCandidate: Candidate?
    private var scope: Scope?
    private var nextSourceGeneration: UInt64 = 0
    private var acceptedSamples: UInt64 = 0
    private var emittedObservations: UInt64 = 0
    private var failed = false

    package init() {}

    @discardableResult
    package func observe(
        projection: HostAgentBackgroundProjectionView?,
        coherentConfigRevision: UInt64?,
        sourceToken: UInt64
    ) -> HostAgentApplicationConcurrencyObservation? {
        guard sourceToken > 0 else { return nil }
        let candidate = Self.candidate(
            projection: projection,
            coherentConfigRevision: coherentConfigRevision
        )

        lock.lock()
        defer { lock.unlock() }
        guard !failed,
              sourceToken >= lastSourceToken,
              sourceToken != lastSourceToken || candidate != lastCandidate
        else { return nil }
        lastSourceToken = sourceToken
        lastCandidate = candidate
        incrementSaturating(&acceptedSamples)

        let observedState: HostAgentConcurrencyRuntimeState
        let observedScope: Scope
        switch candidate {
        case .coherent(let candidateScope, let state):
            if let scope, scope != candidateScope {
                failed = true
                return nil
            }
            scope = candidateScope
            observedScope = candidateScope
            observedState = state
        case .transportUnavailable:
            guard let scope else { return nil }
            observedScope = scope
            observedState = .disconnected
        case .evidenceUnavailable:
            return nil
        }

        guard nextSourceGeneration < UInt64.max else {
            failed = true
            return nil
        }
        nextSourceGeneration += 1
        incrementSaturating(&emittedObservations)
        return HostAgentApplicationConcurrencyObservation(
            state: observedState,
            peerIdentity: observedScope.peerIdentity,
            configRevision: observedScope.configRevision,
            sourceGeneration: nextSourceGeneration
        )
    }

    /// Re-emits only the exact latest coherent projection state. Viewer
    /// lifecycle boundaries use this to prove that an unchanged Host state
    /// still holds after the Viewer edge; unavailable or stale evidence is
    /// never resurrected from an older coherent sample.
    package func reaffirmCurrentCoherentObservation()
        -> HostAgentApplicationConcurrencyObservation?
    {
        lock.lock()
        defer { lock.unlock() }
        guard !failed,
              case .coherent(let candidateScope, let state) = lastCandidate,
              state == .readyZeroInbound || state == .inboundMediaActive,
              scope == candidateScope,
              nextSourceGeneration < UInt64.max
        else { return nil }
        nextSourceGeneration += 1
        incrementSaturating(&emittedObservations)
        return HostAgentApplicationConcurrencyObservation(
            state: state,
            peerIdentity: candidateScope.peerIdentity,
            configRevision: candidateScope.configRevision,
            sourceGeneration: nextSourceGeneration
        )
    }

    package func snapshot()
        -> HostAgentApplicationConcurrencyObservationStateView
    {
        lock.lock()
        defer { lock.unlock() }
        return HostAgentApplicationConcurrencyObservationStateView(
            acceptedSamples: acceptedSamples,
            emittedObservations: emittedObservations,
            lastSourceGeneration: nextSourceGeneration,
            scopeBound: scope != nil,
            failed: failed
        )
    }

    private static func candidate(
        projection: HostAgentBackgroundProjectionView?,
        coherentConfigRevision: UInt64?
    ) -> Candidate {
        guard let projection else { return .transportUnavailable }
        guard case .available(let available) = projection.phase else {
            return .transportUnavailable
        }
        guard let coherentConfigRevision,
              coherentConfigRevision > 0,
              let state = HostAgentConcurrencyRuntimeStatePolicy.classify(
                hostState: available.payload.hostState,
                registrationStatus: available.payload.registrationStatus,
                authenticatedConnectionCount:
                    available.payload.authenticatedConnectionCount,
                hasActiveSession: available.payload.activeSession != nil
              )
        else { return .evidenceUnavailable }
        return .coherent(
            scope: Scope(
                peerIdentity: available.peerIdentity,
                configRevision: coherentConfigRevision
            ),
            state: state
        )
    }

    private func incrementSaturating(_ value: inout UInt64) {
        if value < UInt64.max { value += 1 }
    }
}
