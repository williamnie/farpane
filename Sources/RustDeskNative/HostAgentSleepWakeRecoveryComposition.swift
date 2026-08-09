import CoreBridge
import Foundation

/// Product operations that are deliberately not synthesized by the recovery
/// composition. Each closure must be backed by one authoritative HostAgent
/// subsystem before the composition can be installed in the running process.
struct HostAgentSleepWakeRecoveryProductOperations: Sendable {
    let withdrawAvailability: @Sendable () -> Bool
    let publishSuspending: @Sendable () -> Bool
    let releaseSleepAssertion: @Sendable () -> Bool
    let reenumerateDisplays: @Sendable () -> Bool
    let revalidatePermissions: @Sendable () -> Bool
    let resumeRegistration: @Sendable () -> Bool
    let publishAvailable: @Sendable () -> Bool

    init(
        withdrawAvailability: @escaping @Sendable () -> Bool,
        publishSuspending: @escaping @Sendable () -> Bool,
        releaseSleepAssertion: @escaping @Sendable () -> Bool,
        reenumerateDisplays: @escaping @Sendable () -> Bool,
        revalidatePermissions: @escaping @Sendable () -> Bool,
        resumeRegistration: @escaping @Sendable () -> Bool,
        publishAvailable: @escaping @Sendable () -> Bool
    ) {
        self.withdrawAvailability = withdrawAvailability
        self.publishSuspending = publishSuspending
        self.releaseSleepAssertion = releaseSleepAssertion
        self.reenumerateDisplays = reenumerateDisplays
        self.revalidatePermissions = revalidatePermissions
        self.resumeRegistration = resumeRegistration
        self.publishAvailable = publishAvailable
    }
}

/// Executable-private composition between the toolkit-independent recovery
/// state machine and HostAgent's real media pipeline. Media pause/recovery are
/// intentionally not injectable so product wiring cannot bypass exact-epoch
/// convergence with a placeholder success operation.
final class HostAgentSleepWakeRecoveryComposition: @unchecked Sendable {
    private let owner: HostAgentSleepWakeRecoveryOwner

    init(
        mediaPipelineOwner: HostAgentMediaPipelineOwner,
        operations: HostAgentSleepWakeRecoveryProductOperations
    ) {
        self.owner = HostAgentSleepWakeRecoveryOwner(
            operations: HostAgentSleepWakeRecoveryOperations(
                withdrawAvailability: operations.withdrawAvailability,
                publishSuspending: operations.publishSuspending,
                pauseMediaAndFlush: {
                    mediaPipelineOwner.pauseMediaAndFlushForSleep()
                },
                releaseSleepAssertion: operations.releaseSleepAssertion,
                reenumerateDisplays: operations.reenumerateDisplays,
                revalidatePermissions: operations.revalidatePermissions,
                beginMediaRecovery: { epoch, completion in
                    mediaPipelineOwner.beginMediaRecoveryAfterWake(
                        epoch: epoch,
                        completion: completion
                    )
                },
                resumeRegistration: operations.resumeRegistration,
                publishAvailable: operations.publishAvailable
            )
        )
    }

    deinit {
        cancel()
    }

    func snapshot() -> HostAgentSleepWakeRecoveryState {
        owner.snapshot()
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
    }
}
