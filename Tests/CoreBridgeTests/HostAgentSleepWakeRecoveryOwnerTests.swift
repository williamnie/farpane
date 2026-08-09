@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentSleepWakeRecoveryOwnerTests: XCTestCase {
    func testWakeWaitsForExactMediaEpochBeforeRestoringAvailability() {
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
        XCTAssertEqual(owner.snapshot(), .waitingForMedia(epoch: 1))
        XCTAssertEqual(recorder.steps, [
            .withdrawAvailability,
            .publishSuspending,
            .pauseMediaAndFlush,
            .releaseSleepAssertion,
            .reenumerateDisplays,
            .revalidatePermissions,
            .rebuildMedia,
        ])

        recorder.completeMedia(epoch: 0, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .waitingForMedia(epoch: 1))
        XCTAssertFalse(recorder.steps.contains(.resumeRegistration))
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))

        recorder.completeMedia(epoch: 1, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .waitingForRegistration(epoch: 1))
        XCTAssertEqual(recorder.steps.last, .resumeRegistration)
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))

        recorder.completeRegistration(epoch: 0, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .waitingForRegistration(epoch: 1))
        recorder.completeRegistration(epoch: 1, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .running(epoch: 1))
        XCTAssertEqual(recorder.steps.last, .publishAvailable)
        XCTAssertEqual(recorder.epochs, [1, 1, 1, 1])
        XCTAssertFalse(owner.systemDidWake())

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

    func testWakePreflightFailureNeverBeginsMediaOrRegistration() {
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

    func testRejectedMediaBeginFailsClosedWithoutRegistration() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: recorder,
                rejectMediaBegin: true
            )
        )
        XCTAssertTrue(owner.systemWillSleep())

        XCTAssertFalse(owner.systemDidWake())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .rebuildMedia)
        )
        XCTAssertTrue(recorder.steps.contains(.rebuildMedia))
        XCTAssertFalse(recorder.steps.contains(.resumeRegistration))
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))
    }

    func testFailedMediaCompletionFailsClosedWithoutRegistration() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(recorder: recorder)
        )
        XCTAssertTrue(owner.systemWillSleep())
        XCTAssertTrue(owner.systemDidWake())

        recorder.completeMedia(epoch: 1, succeeded: false)

        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .rebuildMedia)
        )
        XCTAssertFalse(recorder.steps.contains(.resumeRegistration))
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))
        recorder.completeMedia(epoch: 1, succeeded: true)
        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .rebuildMedia)
        )
    }

    func testRejectedRegistrationBeginAfterMediaSuccessDoesNotPublishAvailable() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: recorder,
                rejectRegistrationBegin: true
            )
        )
        XCTAssertTrue(owner.systemWillSleep())
        XCTAssertTrue(owner.systemDidWake())

        recorder.completeMedia(epoch: 1, succeeded: true)

        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .resumeRegistration)
        )
        XCTAssertEqual(
            recorder.steps.filter { $0 == .resumeRegistration }.count,
            1
        )
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))
    }

    func testFailedRegistrationCompletionDoesNotPublishAvailable() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(recorder: recorder)
        )
        XCTAssertTrue(owner.systemWillSleep())
        XCTAssertTrue(owner.systemDidWake())
        recorder.completeMedia(epoch: 1, succeeded: true)

        recorder.completeRegistration(epoch: 1, succeeded: false)

        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .resumeRegistration)
        )
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))
        recorder.completeRegistration(epoch: 1, succeeded: true)
        XCTAssertEqual(
            owner.snapshot(),
            .failed(epoch: 1, step: .resumeRegistration)
        )
    }

    func testDuplicateAndFutureMediaCompletionCannotAdvanceEpochTwice() {
        let recorder = SleepWakeRecoveryRecorder()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(recorder: recorder)
        )
        XCTAssertTrue(owner.systemWillSleep())
        XCTAssertTrue(owner.systemDidWake())

        recorder.completeMedia(epoch: 2, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .waitingForMedia(epoch: 1))
        recorder.completeMedia(epoch: 1, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .waitingForRegistration(epoch: 1))
        recorder.completeMedia(epoch: 1, succeeded: false)
        XCTAssertEqual(owner.snapshot(), .waitingForRegistration(epoch: 1))
        recorder.completeRegistration(epoch: 2, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .waitingForRegistration(epoch: 1))
        recorder.completeRegistration(epoch: 1, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .running(epoch: 1))
        recorder.completeRegistration(epoch: 1, succeeded: false)
        XCTAssertEqual(owner.snapshot(), .running(epoch: 1))
        XCTAssertEqual(
            recorder.steps.filter { $0 == .resumeRegistration }.count,
            1
        )
        XCTAssertEqual(
            recorder.steps.filter { $0 == .publishAvailable }.count,
            1
        )
    }

    func testSynchronousMediaCompletionWaitsForAcceptedBeginResult() {
        let acceptedRecorder = SleepWakeRecoveryRecorder()
        let acceptedOwner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: acceptedRecorder,
                synchronousMediaResult: true,
                synchronousRegistrationResult: true
            )
        )
        XCTAssertTrue(acceptedOwner.systemWillSleep())
        XCTAssertTrue(acceptedOwner.systemDidWake())
        XCTAssertEqual(acceptedOwner.snapshot(), .running(epoch: 1))
        XCTAssertEqual(Array(acceptedRecorder.steps.suffix(3)), [
            .rebuildMedia,
            .resumeRegistration,
            .publishAvailable,
        ])

        let rejectedRecorder = SleepWakeRecoveryRecorder()
        let rejectedOwner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: rejectedRecorder,
                rejectMediaBegin: true,
                synchronousMediaResult: true
            )
        )
        XCTAssertTrue(rejectedOwner.systemWillSleep())
        XCTAssertFalse(rejectedOwner.systemDidWake())
        XCTAssertEqual(
            rejectedOwner.snapshot(),
            .failed(epoch: 1, step: .rebuildMedia)
        )
        XCTAssertFalse(rejectedRecorder.steps.contains(.resumeRegistration))
        XCTAssertFalse(rejectedRecorder.steps.contains(.publishAvailable))
    }

    func testCancellationDuringMediaBeginDropsSynchronousAndLateCompletion() {
        let recorder = SleepWakeRecoveryRecorder()
        let ownerBox = SleepWakeRecoveryOwnerBox()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: operations(
                recorder: recorder,
                synchronousMediaResult: true,
                duringMediaBegin: { ownerBox.owner?.cancel() }
            )
        )
        ownerBox.owner = owner
        XCTAssertTrue(owner.systemWillSleep())

        XCTAssertFalse(owner.systemDidWake())
        XCTAssertEqual(owner.snapshot(), .cancelled)
        recorder.completeMedia(epoch: 1, succeeded: true)
        XCTAssertEqual(owner.snapshot(), .cancelled)
        XCTAssertFalse(recorder.steps.contains(.resumeRegistration))
        XCTAssertFalse(recorder.steps.contains(.publishAvailable))
    }

    func testReentrantWakeAndCancellationCannotResumeSleepTransition() {
        let recorder = SleepWakeRecoveryRecorder()
        let ownerBox = SleepWakeRecoveryOwnerBox()
        let owner = HostAgentSleepWakeRecoveryOwner(
            operations: HostAgentSleepWakeRecoveryOperations(
                withdrawAvailability: { epoch in
                    recorder.record(.withdrawAvailability, epoch: epoch)
                    XCTAssertFalse(ownerBox.owner?.systemDidWake() ?? true)
                    ownerBox.owner?.cancel()
                    return true
                },
                publishSuspending: recorder.epochOperation(.publishSuspending),
                pauseMediaAndFlush: recorder.operation(.pauseMediaAndFlush),
                releaseSleepAssertion: recorder.epochOperation(
                    .releaseSleepAssertion
                ),
                reenumerateDisplays: recorder.operation(.reenumerateDisplays),
                revalidatePermissions: recorder.operation(.revalidatePermissions),
                beginMediaRecovery: recorder.beginMediaRecovery(),
                beginRegistrationRecovery: recorder.beginRegistrationRecovery(),
                publishAvailable: recorder.epochOperation(.publishAvailable)
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
        failingAt failure: HostAgentSleepWakeRecoveryStep? = nil,
        rejectMediaBegin: Bool = false,
        synchronousMediaResult: Bool? = nil,
        duringMediaBegin: (@Sendable () -> Void)? = nil,
        rejectRegistrationBegin: Bool = false,
        synchronousRegistrationResult: Bool? = nil
    ) -> HostAgentSleepWakeRecoveryOperations {
        HostAgentSleepWakeRecoveryOperations(
            withdrawAvailability: recorder.epochOperation(
                .withdrawAvailability,
                failingAt: failure
            ),
            publishSuspending: recorder.epochOperation(
                .publishSuspending,
                failingAt: failure
            ),
            pauseMediaAndFlush: recorder.operation(
                .pauseMediaAndFlush,
                failingAt: failure
            ),
            releaseSleepAssertion: recorder.epochOperation(
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
            beginMediaRecovery: recorder.beginMediaRecovery(
                rejecting: rejectMediaBegin,
                synchronousResult: synchronousMediaResult,
                duringBegin: duringMediaBegin
            ),
            beginRegistrationRecovery: recorder.beginRegistrationRecovery(
                rejecting: rejectRegistrationBegin,
                synchronousResult: synchronousRegistrationResult
            ),
            publishAvailable: recorder.epochOperation(
                .publishAvailable,
                failingAt: failure
            )
        )
    }
}

private final class SleepWakeRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stepStorage: [HostAgentSleepWakeRecoveryStep] = []
    private var epochStorage: [UInt64] = []
    private var mediaCompletion: HostAgentSleepWakeMediaRecoveryCompletion?
    private var registrationCompletion:
        HostAgentSleepWakeRegistrationRecoveryCompletion?

    var steps: [HostAgentSleepWakeRecoveryStep] {
        lock.lock()
        defer { lock.unlock() }
        return stepStorage
    }

    var epochs: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return epochStorage
    }

    func record(_ step: HostAgentSleepWakeRecoveryStep) {
        lock.lock()
        stepStorage.append(step)
        lock.unlock()
    }

    func record(_ step: HostAgentSleepWakeRecoveryStep, epoch: UInt64) {
        lock.lock()
        stepStorage.append(step)
        epochStorage.append(epoch)
        lock.unlock()
    }

    func epochOperation(
        _ step: HostAgentSleepWakeRecoveryStep,
        failingAt failure: HostAgentSleepWakeRecoveryStep? = nil
    ) -> @Sendable (UInt64) -> Bool {
        { [self] epoch in
            record(step, epoch: epoch)
            return step != failure
        }
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

    func beginMediaRecovery(
        rejecting: Bool = false,
        synchronousResult: Bool? = nil,
        duringBegin: (@Sendable () -> Void)? = nil
    ) -> @Sendable (
        UInt64,
        @escaping HostAgentSleepWakeMediaRecoveryCompletion
    ) -> Bool {
        { [self] epoch, completion in
            lock.lock()
            stepStorage.append(.rebuildMedia)
            mediaCompletion = completion
            lock.unlock()
            duringBegin?()
            if let synchronousResult {
                completion(epoch, synchronousResult)
            }
            return !rejecting
        }
    }

    func completeMedia(epoch: UInt64, succeeded: Bool) {
        lock.lock()
        let completion = mediaCompletion
        lock.unlock()
        completion?(epoch, succeeded)
    }

    func beginRegistrationRecovery(
        rejecting: Bool = false,
        synchronousResult: Bool? = nil
    ) -> @Sendable (
        UInt64,
        @escaping HostAgentSleepWakeRegistrationRecoveryCompletion
    ) -> Bool {
        { [self] epoch, completion in
            lock.lock()
            stepStorage.append(.resumeRegistration)
            registrationCompletion = completion
            lock.unlock()
            if let synchronousResult {
                completion(epoch, synchronousResult)
            }
            return !rejecting
        }
    }

    func completeRegistration(epoch: UInt64, succeeded: Bool) {
        lock.lock()
        let completion = registrationCompletion
        lock.unlock()
        completion?(epoch, succeeded)
    }
}

private final class SleepWakeRecoveryOwnerBox: @unchecked Sendable {
    weak var owner: HostAgentSleepWakeRecoveryOwner?
}
