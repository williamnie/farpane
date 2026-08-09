import CoreBridge
import Foundation

/// Product operations that are deliberately not synthesized by the recovery
/// composition. Each closure must be backed by one authoritative HostAgent
/// subsystem before the composition can be installed in the running process.
struct HostAgentSleepWakeRecoveryProductOperations: Sendable {
    let publishSuspending: @Sendable (_ epoch: UInt64) -> Bool
    let publishAvailable: @Sendable (_ epoch: UInt64) -> Bool
    let recoveryAccepted: @Sendable (_ epoch: UInt64) -> Void
    let recoveryCompleted: @Sendable (_ epoch: UInt64) -> Void

    init(
        publishSuspending: @escaping @Sendable (_ epoch: UInt64) -> Bool,
        publishAvailable: @escaping @Sendable (_ epoch: UInt64) -> Bool,
        recoveryAccepted: @escaping @Sendable (_ epoch: UInt64) -> Void,
        recoveryCompleted: @escaping @Sendable (_ epoch: UInt64) -> Void
    ) {
        self.publishSuspending = publishSuspending
        self.publishAvailable = publishAvailable
        self.recoveryAccepted = recoveryAccepted
        self.recoveryCompleted = recoveryCompleted
    }
}

/// Executable-private composition between the toolkit-independent recovery
/// state machine and HostAgent's real media pipeline. Media pause/recovery are
/// intentionally not injectable so product wiring cannot bypass exact-epoch
/// convergence with a placeholder success operation.
final class HostAgentSleepWakeRecoveryComposition: @unchecked Sendable {
    private let owner: HostAgentSleepWakeRecoveryOwner
    private let displayTCCAuthority: HostAgentDisplayTCCRecoveryAuthority
    private let registrationRecoveryOwner:
        HostAgentRegistrationRecoveryPollingOwner

    init(
        mediaPipelineOwner: HostAgentMediaPipelineOwner,
        displayTCCAuthority: HostAgentDisplayTCCRecoveryAuthority,
        lifetime: HostAgentProcessLifetime,
        expectedHostInstanceID: String,
        operations: HostAgentSleepWakeRecoveryProductOperations
    ) {
        let registrationRecoveryOwner =
            HostAgentRegistrationRecoveryPollingOwner.makeProduct(
                expectedHostInstanceID: expectedHostInstanceID,
                resume: { [weak lifetime] epoch in
                    guard let lifetime else { return false }
                    do {
                        try lifetime.resumeAfterWake(epoch: epoch)
                        return true
                    } catch {
                        return false
                    }
                },
                observe: { [weak lifetime] in
                    guard let lifetime else { return .failed }
                    do {
                        return .snapshot(try lifetime.copySnapshot())
                    } catch HostAgentProcessLifetimeAccessError.notRunning {
                        return .failed
                    } catch {
                        return .unavailable
                    }
                }
            )
        self.displayTCCAuthority = displayTCCAuthority
        self.registrationRecoveryOwner = registrationRecoveryOwner
        self.owner = HostAgentSleepWakeRecoveryOwner(
            operations: HostAgentSleepWakeRecoveryOperations(
                withdrawAvailability: { [weak lifetime] epoch in
                    guard let lifetime else { return false }
                    do {
                        try lifetime.beginSleep(epoch: epoch)
                        return true
                    } catch {
                        return false
                    }
                },
                publishSuspending: { epoch in
                    operations.publishSuspending(epoch)
                },
                pauseMediaAndFlush: {
                    mediaPipelineOwner.pauseMediaAndFlushForSleep()
                },
                releaseSleepAssertion: { [weak lifetime] epoch in
                    guard let lifetime else { return false }
                    do {
                        try lifetime.finishSleep(epoch: epoch)
                        return true
                    } catch {
                        return false
                    }
                },
                reenumerateDisplays: {
                    displayTCCAuthority.reenumerateDisplays()
                },
                revalidatePermissions: {
                    displayTCCAuthority.revalidatePermissions()
                },
                beginMediaRecovery: { epoch, completion in
                    mediaPipelineOwner.beginMediaRecoveryAfterWake(
                        epoch: epoch,
                        completion: completion
                    )
                },
                beginRegistrationRecovery: { epoch, completion in
                    registrationRecoveryOwner.start(
                        epoch: epoch,
                        completion: completion
                    )
                },
                publishAvailable: { epoch in
                    operations.publishAvailable(epoch)
                },
                recoveryAccepted: { epoch in
                    operations.recoveryAccepted(epoch)
                },
                recoveryCompleted: { epoch in
                    operations.recoveryCompleted(epoch)
                }
            )
        )
    }

    deinit {
        cancel()
    }

    func snapshot() -> HostAgentSleepWakeRecoveryState {
        owner.snapshot()
    }

    func environmentSnapshot() -> HostAgentDisplayTCCRecoveryState {
        displayTCCAuthority.snapshot()
    }

    func registrationSnapshot() -> HostAgentRegistrationRecoveryState {
        registrationRecoveryOwner.stateSnapshot()
    }

    @discardableResult
    func systemWillSleep() -> Bool {
        owner.systemWillSleep()
    }

    @discardableResult
    func systemDidWake() -> Bool {
        owner.systemDidWake()
    }

    func cancel() {
        owner.cancel()
        registrationRecoveryOwner.cancelAndWait()
        displayTCCAuthority.cancel()
    }
}
