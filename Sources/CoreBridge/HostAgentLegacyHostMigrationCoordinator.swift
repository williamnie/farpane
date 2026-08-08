import Foundation

package enum HostAgentLegacyHostMigrationIntent: Equatable, Sendable {
    case prepareForBackgroundRegistration
}

package enum HostAgentLegacyHostQuiescenceRequestResult:
    Equatable,
    Sendable
{
    case completed
    case failed
}

package enum HostAgentLegacyHostMigrationCoordinatorFailure:
    Equatable,
    Sendable
{
    case assessment(HostAgentLegacyHostMigrationFailure)
    case quiescenceRequestFailed
}

package enum HostAgentLegacyHostMigrationCoordinatorPhase:
    Equatable,
    Sendable
{
    case idle
    case assessing
    case quiescing
    case readyForRegistration
    case blocked(Set<HostAgentLegacyHostMigrationBlocker>)
    case failed(HostAgentLegacyHostMigrationCoordinatorFailure)
}

package struct HostAgentLegacyHostMigrationCoordinatorView:
    Equatable,
    Sendable
{
    package let phase: HostAgentLegacyHostMigrationCoordinatorPhase

    fileprivate init(phase: HostAgentLegacyHostMigrationCoordinatorPhase) {
        self.phase = phase
    }
}

/// Coordinates a single explicit migration preparation attempt. Session work
/// is never interrupted automatically. Safe residual ownership may request one
/// quiescence operation, whose return value is insufficient without a second
/// authoritative evidence capture and migration-gate assessment.
package final class HostAgentLegacyHostMigrationCoordinator:
    @unchecked Sendable
{
    package typealias EvidenceCapture = @Sendable () ->
        HostAgentLegacyHostMigrationEvidence
    package typealias QuiescenceRequest = @Sendable () ->
        HostAgentLegacyHostQuiescenceRequestResult

    private static let interactiveBlockers: Set<
        HostAgentLegacyHostMigrationBlocker
    > = [
        .pendingApproval,
        .activeSession,
    ]

    private let stateLock = NSLock()
    private let captureEvidence: EvidenceCapture
    private let requestQuiescence: QuiescenceRequest
    private var operationInFlight = false
    private var view = HostAgentLegacyHostMigrationCoordinatorView(
        phase: .idle
    )

    package init(
        captureEvidence: @escaping EvidenceCapture,
        requestQuiescence: @escaping QuiescenceRequest
    ) {
        self.captureEvidence = captureEvidence
        self.requestQuiescence = requestQuiescence
    }

    package func snapshot() -> HostAgentLegacyHostMigrationCoordinatorView {
        stateLock.lock()
        defer { stateLock.unlock() }
        return view
    }

    @discardableResult
    package func apply(
        _ intent: HostAgentLegacyHostMigrationIntent
    ) -> Bool {
        switch intent {
        case .prepareForBackgroundRegistration:
            return prepareForBackgroundRegistration()
        }
    }

    private func prepareForBackgroundRegistration() -> Bool {
        stateLock.lock()
        guard !operationInFlight else {
            stateLock.unlock()
            return false
        }
        operationInFlight = true
        view = HostAgentLegacyHostMigrationCoordinatorView(
            phase: .assessing
        )
        stateLock.unlock()

        let initialAssessment = HostAgentLegacyHostMigrationGate.assess(
            captureEvidence()
        )
        switch initialAssessment {
        case .eligible:
            return finish(.readyForRegistration)
        case .failed(let failure):
            return finish(.failed(.assessment(failure)))
        case .blocked(let blockers):
            guard blockers.isDisjoint(with: Self.interactiveBlockers) else {
                return finish(.blocked(blockers))
            }
        }

        updatePhase(.quiescing)
        let requestResult = requestQuiescence()
        let freshAssessment = HostAgentLegacyHostMigrationGate.assess(
            captureEvidence()
        )
        guard requestResult == .completed else {
            return finish(.failed(.quiescenceRequestFailed))
        }

        switch freshAssessment {
        case .eligible:
            return finish(.readyForRegistration)
        case .blocked(let blockers):
            return finish(.blocked(blockers))
        case .failed(let failure):
            return finish(.failed(.assessment(failure)))
        }
    }

    private func updatePhase(
        _ phase: HostAgentLegacyHostMigrationCoordinatorPhase
    ) {
        stateLock.lock()
        view = HostAgentLegacyHostMigrationCoordinatorView(phase: phase)
        stateLock.unlock()
    }

    private func finish(
        _ phase: HostAgentLegacyHostMigrationCoordinatorPhase
    ) -> Bool {
        stateLock.lock()
        view = HostAgentLegacyHostMigrationCoordinatorView(phase: phase)
        operationInFlight = false
        stateLock.unlock()
        return phase == .readyForRegistration
    }
}
