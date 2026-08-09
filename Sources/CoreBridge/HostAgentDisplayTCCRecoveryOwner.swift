import Foundation

package struct HostAgentRecoveryDisplay: Equatable, Sendable {
    package let canonicalID: UInt32
    package let pixelWidth: UInt32
    package let pixelHeight: UInt32
    package let originX: Double
    package let originY: Double
    package let rotationDegrees: Double
    package let isMain: Bool

    package init(
        canonicalID: UInt32,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        originX: Double = 0,
        originY: Double = 0,
        rotationDegrees: Double = 0,
        isMain: Bool
    ) {
        self.canonicalID = canonicalID
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.originX = originX
        self.originY = originY
        self.rotationDegrees = rotationDegrees
        self.isMain = isMain
    }
}

package struct HostAgentRecoveryPermissionSnapshot: Equatable, Sendable {
    package let screenCaptureGranted: Bool
    package let accessibilityGranted: Bool
    package let inputMonitoringGranted: Bool

    package init(
        screenCaptureGranted: Bool,
        accessibilityGranted: Bool,
        inputMonitoringGranted: Bool
    ) {
        self.screenCaptureGranted = screenCaptureGranted
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoringGranted = inputMonitoringGranted
    }
}

package struct HostAgentRecoveryEnvironmentSnapshot: Equatable, Sendable {
    package let revision: UInt64
    package let displays: [HostAgentRecoveryDisplay]
    package let permissions: HostAgentRecoveryPermissionSnapshot

    package init(
        revision: UInt64,
        displays: [HostAgentRecoveryDisplay],
        permissions: HostAgentRecoveryPermissionSnapshot
    ) {
        self.revision = revision
        self.displays = displays
        self.permissions = permissions
    }
}

package enum HostAgentDisplayTCCRecoveryFailure: String, Equatable, Sendable {
    case generationExhausted
    case displayUnavailable
    case displayChangedDuringValidation
    case screenCaptureDenied
    case accessibilityDenied
}

package enum HostAgentDisplayTCCRecoveryState: Equatable, Sendable {
    case idle(revision: UInt64)
    case enumerating(revision: UInt64)
    case awaitingPermissions(
        revision: UInt64,
        displays: [HostAgentRecoveryDisplay]
    )
    case validatingPermissions(
        revision: UInt64,
        displays: [HostAgentRecoveryDisplay]
    )
    case ready(HostAgentRecoveryEnvironmentSnapshot)
    case failed(revision: UInt64, failure: HostAgentDisplayTCCRecoveryFailure)
    case cancelled
}

package struct HostAgentDisplayTCCRecoveryOperations: Sendable {
    package let enumerateDisplays: @Sendable () -> [HostAgentRecoveryDisplay]?
    package let observePermissions:
        @Sendable () -> HostAgentRecoveryPermissionSnapshot

    package init(
        enumerateDisplays: @escaping @Sendable () -> [HostAgentRecoveryDisplay]?,
        observePermissions: @escaping @Sendable () -> (
            HostAgentRecoveryPermissionSnapshot
        )
    ) {
        self.enumerateDisplays = enumerateDisplays
        self.observePermissions = observePermissions
    }
}

/// Produces one coherent, revisioned wake environment without importing any
/// macOS UI toolkit. A ready snapshot requires the active display inventory to
/// be identical before and after non-prompting TCC observation.
package final class HostAgentDisplayTCCRecoveryOwner: @unchecked Sendable {
    private let lock = NSLock()
    private let operations: HostAgentDisplayTCCRecoveryOperations
    private var state: HostAgentDisplayTCCRecoveryState

    package init(
        initialRevision: UInt64 = 0,
        operations: HostAgentDisplayTCCRecoveryOperations
    ) {
        self.operations = operations
        self.state = .idle(revision: initialRevision)
    }

    package func snapshot() -> HostAgentDisplayTCCRecoveryState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    @discardableResult
    package func reenumerateDisplays() -> Bool {
        lock.lock()
        let currentRevision: UInt64
        switch state {
        case .idle(let revision):
            currentRevision = revision
        case .ready(let snapshot):
            currentRevision = snapshot.revision
        default:
            lock.unlock()
            return false
        }
        guard currentRevision < UInt64.max else {
            state = .failed(
                revision: currentRevision,
                failure: .generationExhausted
            )
            lock.unlock()
            return false
        }
        let revision = currentRevision + 1
        let transition = HostAgentDisplayTCCRecoveryState.enumerating(
            revision: revision
        )
        state = transition
        lock.unlock()

        guard let rawDisplays = operations.enumerateDisplays(),
              let displays = Self.normalize(rawDisplays)
        else {
            return fail(
                transition,
                revision: revision,
                failure: .displayUnavailable
            )
        }

        lock.lock()
        defer { lock.unlock() }
        guard state == transition else { return false }
        state = .awaitingPermissions(
            revision: revision,
            displays: displays
        )
        return true
    }

    @discardableResult
    package func revalidatePermissions() -> Bool {
        lock.lock()
        guard case .awaitingPermissions(let revision, let displays) = state
        else {
            lock.unlock()
            return false
        }
        let transition = HostAgentDisplayTCCRecoveryState.validatingPermissions(
            revision: revision,
            displays: displays
        )
        state = transition
        lock.unlock()

        let permissions = operations.observePermissions()
        lock.lock()
        guard state == transition else {
            lock.unlock()
            return false
        }
        guard permissions.screenCaptureGranted else {
            state = .failed(
                revision: revision,
                failure: .screenCaptureDenied
            )
            lock.unlock()
            return false
        }
        guard permissions.accessibilityGranted else {
            state = .failed(
                revision: revision,
                failure: .accessibilityDenied
            )
            lock.unlock()
            return false
        }
        lock.unlock()

        guard let rawDisplays = operations.enumerateDisplays(),
              let confirmedDisplays = Self.normalize(rawDisplays)
        else {
            return fail(
                transition,
                revision: revision,
                failure: .displayUnavailable
            )
        }

        lock.lock()
        defer { lock.unlock() }
        guard state == transition else { return false }
        guard confirmedDisplays == displays else {
            state = .failed(
                revision: revision,
                failure: .displayChangedDuringValidation
            )
            return false
        }
        state = .ready(HostAgentRecoveryEnvironmentSnapshot(
            revision: revision,
            displays: displays,
            permissions: permissions
        ))
        return true
    }

    package func cancel() {
        lock.lock()
        state = .cancelled
        lock.unlock()
    }

    private func fail(
        _ expected: HostAgentDisplayTCCRecoveryState,
        revision: UInt64,
        failure: HostAgentDisplayTCCRecoveryFailure
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == expected else { return false }
        state = .failed(revision: revision, failure: failure)
        return false
    }

    private static func normalize(
        _ displays: [HostAgentRecoveryDisplay]
    ) -> [HostAgentRecoveryDisplay]? {
        guard !displays.isEmpty,
              displays.allSatisfy({
                  $0.canonicalID > 0
                      && $0.pixelWidth > 0
                      && $0.pixelHeight > 0
                      && $0.originX.isFinite
                      && $0.originY.isFinite
                      && $0.rotationDegrees.isFinite
              }),
              displays.filter(\.isMain).count == 1
        else { return nil }
        let ordered = displays.sorted {
            $0.canonicalID < $1.canonicalID
        }
        for index in ordered.indices.dropFirst()
        where ordered[index - 1].canonicalID == ordered[index].canonicalID {
            return nil
        }
        return ordered
    }
}
