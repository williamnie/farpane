@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentSleepWakeRecoveryOwnerTests: XCTestCase {
    func testSleepAndWakeRunExactOrderOncePerEpoch() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(recorder: recorder)
        )

        XCTAssertEqual(owner.snapshot(), .running(epoch: 0))
        XCTAssertFalse(owner.systemDidWake())
        XCTAssertTrue(owner.systemWillSleep())
        XCTAssertEqual(owner.snapshot(), .sleeping(epoch: 1))
        XCTAssertFalse(owner.systemWillSleep())
        XCTAssertTrue(owner.systemDidWake())
        XCTAssertEqual(owner.snapshot(), .running(epoch: 1))
        XCTAssertFalse(owner.systemDidWake())
        XCTAssertEqual(recorder.steps, [
            .withdrawAvailability,
            .publishSuspending,
            .pauseMediaAndFlush,
            .releaseSleepAssertion,
            .reenumerateDisplays,
            .revalidatePermissions,
            .rebuildMedia,
            .resumeRegistration,
            .publishAvailable,
        ])

        XCTAssertTrue(owner.systemWillSleep())
        XCTAssertEqual(owner.snapshot(), .sleeping(epoch: 2))
    }

    func testSleepFailureStillAttemptsAssertionReleaseAndRejectsWake() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: recorder,
                failingAt: .withdrawAvailability
            )
        )

        XCTAssertFalse(owner.systemWillSleep())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .withdrawAvailability)
        )
        XCTAssertEqual(recorder.steps, [
            .withdrawAvailability,
            .publishSuspending,
            .pauseMediaAndFlush,
            .releaseSleepAssertion,
        ])
        XCTAssertFalse(owner.systemDidWake())
        XCTAssertFalse(owner.systemWillSleep())
        XCTAssertEqual(recorder.steps.count, 4)
    }

    func testWakeFailureKeepsRegistrationAndAvailabilityWithdrawn() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: recorder,
                failingAt: .revalidatePermissions
            )
        )
        XCTAssertTrue(owner.systemWillSleep())

        XCTAssertFalse(owner.systemDidWake())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .revalidatePermissions)
        )
        XCTAssertEqual(recorder.steps, [
            .withdrawAvailability,
            .publishSuspending,
            .pauseMediaAndFlush,
            .releaseSleepAssertion,
            .reenumerateDisplays,
            .revalidatePermissions,
        ])
        XCTAssertFalse(recorder.steps.contains(.rebuildMedia))
        XCTAssertFalse(recorder.steps.contains(.resumeRegistration))
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))
    }

    func testReentrantWakeAndCancellationCannotResumeTransition() {
        let recorder = SleepWakeRecoveryRecorder()
        let ownerBox = SleepWakeRecoveryOwnerBox()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: HostAgentSleepWakeRecoveryOperations(
                withdrawAvailability: {
                    recorder.record(.withdrawAvailability)
                    XCTAssertFalse(ownerBox.owner?.systemDidWake() ?? true)
                    ownerBox.owner?.cancel()
                    return true
                },
                publishSuspending: recorder.operation(.publishSuspending),
                pauseMediaAndFlush: recorder.operation(.pauseMediaAndFlush),
                releaseSleepAssertion: recorder.operation(.releaseSleepAssertion),
                reenumerateDisplays: recorder.operation(.reenumerateDisplays),
                revalidatePermissions: recorder.operation(.revalidatePermissions),
                rebuildMedia: recorder.operation(.rebuildMedia),
                resumeRegistration: recorder.operation(.resumeRegistration),
                publishAvailable: recorder.operation(.publishAvailable)
            )
        )
        ownerBox.owner = owner

        XCTAssertFalse(owner.systemWillSleep())
        XCTAssertEqual(owner.snapshot(), .cancelled)
        XCTAssertEqual(recorder.steps, [.withdrawAvailability])
        XCTAssertFalse(owner.systemDidWake())
    }

    func testGenerationExhaustionFailsWithoutInvokingOperations() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            initialEpoch: UInt64.max,
            operations: operations(recorder: recorder)
        )

        XCTAssertFalse(owner.systemWillSleep())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: UInt64.max, step: .generationExhausted)
        )
        XCTAssertTrue(recorder.steps.isEmpty)
    }

    private func operations(
        recorder: SleepWakeRecoveryRecorder,
        failingAt failure: HostAgentSleepWakeRecoveryStep? = nil
    ) -> HostAgentSleepWakeRecoveryOperations {
        HostAgentSleepWakeRecoveryOperations(
            withdrawAvailability: recorder.operation(
                .withdrawAvailability,
                failingAt: failure
            ),
            publishSuspending: recorder.operation(
                .publishSuspending,
                failingAt: failure
            ),
            pauseMediaAndFlush: recorder.operation(
                .pauseMediaAndFlush,
                failingAt: failure
            ),
            releaseSleepAssertion: recorder.operation(
                .releaseSleepAssertion,
                failingAt: failure
            ),
            reenumerateDisplays: recorder.operation(
                .reenumerateDisplays,
                failingAt: failure
            ),
            revalidatePermissions: recorder.operation(
                .revalidatePermissions,
                failingAt: failure
            ),
            rebuildMedia: recorder.operation(
                .rebuildMedia,
                failingAt: failure
            ),
            resumeRegistration: recorder.operation(
                .resumeRegistration,
                failingAt: failure
            ),
            publishAvailable: recorder.operation(
                .publishAvailable,
                failingAt: failure
            )
        )
    }
}

private final class SleepWakeRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HostAgentSleepWakeRecoveryStep] = []

    var steps: [HostAgentSleepWakeRecoveryStep] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ step: HostAgentSleepWakeRecoveryStep) {
        lock.lock()
        storage.append(step)
        lock.unlock()
    }

    func operation(
        _ step: HostAgentSleepWakeRecoveryStep,
        failingAt failure: HostAgentSleepWakeRecoveryStep? = nil
    ) -> @Sendable () -> Bool {
        { [self] in
            record(step)
            return step != failure
        }
    }
}

private final class SleepWakeRecoveryOwnerBox: @unchecked Sendable {
    weak var owner: HostAgentSleepWakeRecoveryOwner?
}
