@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentDisplayTCCRecoveryOwnerTests: XCTestCase {
    func testReadySnapshotRequiresStableNormalizedInventoryAndRequiredTCC() {
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [
                [secondaryDisplay, mainDisplay],
                [mainDisplay, secondaryDisplay],
                [mainDisplay, secondaryDisplay],
                [secondaryDisplay, mainDisplay],
            ],
            permissions: grantedPermissions(inputMonitoring: false)
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertTrue(owner.reenumerateDisplays())
        XCTAssertEqual(
            owner.snapshot(),
            .awaitingPermissions(
                revision: 1,
                displays: [mainDisplay, secondaryDisplay]
            )
        )
        XCTAssertTrue(owner.revalidatePermissions())
        XCTAssertEqual(
            owner.snapshot(),
            .ready(HostAgentRecoveryEnvironmentSnapshot(
                revision: 1,
                displays: [mainDisplay, secondaryDisplay],
                permissions: grantedPermissions(inputMonitoring: false)
            ))
        )

        XCTAssertTrue(owner.reenumerateDisplays())
        XCTAssertTrue(owner.revalidatePermissions())
        guard case .ready(let secondSnapshot) = owner.snapshot() else {
            return XCTFail("expected second ready snapshot")
        }
        XCTAssertEqual(secondSnapshot.revision, 2)
        XCTAssertEqual(secondSnapshot.displays, [mainDisplay, secondaryDisplay])
        XCTAssertFalse(secondSnapshot.permissions.inputMonitoringGranted)
    }

    func testScreenCaptureDenialFailsBeforeSecondDisplayObservation() {
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [[mainDisplay]],
            permissions: HostAgentRecoveryPermissionSnapshot(
                screenCaptureGranted: false,
                accessibilityGranted: true,
                inputMonitoringGranted: true
            )
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertTrue(owner.reenumerateDisplays())
        XCTAssertFalse(owner.revalidatePermissions())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(revision: 1, failure: .screenCaptureDenied)
        )
        XCTAssertEqual(recorder.enumerationCount, 1)
    }

    func testAccessibilityDenialFailsBeforeSecondDisplayObservation() {
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [[mainDisplay]],
            permissions: HostAgentRecoveryPermissionSnapshot(
                screenCaptureGranted: true,
                accessibilityGranted: false,
                inputMonitoringGranted: true
            )
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertTrue(owner.reenumerateDisplays())
        XCTAssertFalse(owner.revalidatePermissions())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(revision: 1, failure: .accessibilityDenied)
        )
        XCTAssertEqual(recorder.enumerationCount, 1)
    }

    func testDisplayChangeDuringPermissionValidationFailsClosed() {
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [
                [mainDisplay],
                [mainDisplay, secondaryDisplay],
            ],
            permissions: grantedPermissions()
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertTrue(owner.reenumerateDisplays())
        XCTAssertFalse(owner.revalidatePermissions())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(
                revision: 1,
                failure: .displayChangedDuringValidation
            )
        )
    }

    func testDisplayLayoutChangeWithSameIdentityAndDimensionsFailsClosed() {
        let movedSecondary = HostAgentRecoveryDisplay(
            canonicalID: secondaryDisplay.canonicalID,
            pixelWidth: secondaryDisplay.pixelWidth,
            pixelHeight: secondaryDisplay.pixelHeight,
            originX: -1920,
            originY: 0,
            rotationDegrees: secondaryDisplay.rotationDegrees,
            isMain: false
        )
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [
                [mainDisplay, secondaryDisplay],
                [mainDisplay, movedSecondary],
            ],
            permissions: grantedPermissions()
        )
        let owner = makeOwner(recorder: recorder)

        XCTAssertTrue(owner.reenumerateDisplays())
        XCTAssertFalse(owner.revalidatePermissions())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(
                revision: 1,
                failure: .displayChangedDuringValidation
            )
        )
    }

    func testMalformedDisplayInventoriesFailBeforeTCCObservation() {
        let invalidInventories: [[HostAgentRecoveryDisplay]] = [
            [],
            [mainDisplay, mainDisplay],
            [secondaryDisplay],
            [HostAgentRecoveryDisplay(
                canonicalID: 3,
                pixelWidth: 0,
                pixelHeight: 1080,
                isMain: true
            )],
        ]

        for inventory in invalidInventories {
            let recorder = DisplayTCCRecoveryRecorder(
                inventories: [inventory],
                permissions: grantedPermissions()
            )
            let owner = makeOwner(recorder: recorder)
            XCTAssertFalse(owner.reenumerateDisplays())
            XCTAssertEqual(
                owner.snapshot(),
                .failed(revision: 1, failure: .displayUnavailable)
            )
            XCTAssertEqual(recorder.permissionObservationCount, 0)
        }
    }

    func testCancellationDuringEnumerationRejectsLateResult() {
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [[mainDisplay]],
            permissions: grantedPermissions()
        )
        let ownerBox = DisplayTCCRecoveryOwnerBox()
        recorder.onEnumerate = { ownerBox.owner?.cancel() }
        let owner = makeOwner(recorder: recorder)
        ownerBox.owner = owner

        XCTAssertFalse(owner.reenumerateDisplays())
        XCTAssertEqual(owner.snapshot(), .cancelled)
        XCTAssertFalse(owner.revalidatePermissions())
    }

    func testGenerationExhaustionAndInvalidOrderHaveNoObservations() {
        let recorder = DisplayTCCRecoveryRecorder(
            inventories: [[mainDisplay]],
            permissions: grantedPermissions()
        )
        let owner = HostAgentDisplayTCCRecoveryOwner(
            initialRevision: UInt64.max,
            operations: recorder.operations()
        )

        XCTAssertFalse(owner.revalidatePermissions())
        XCTAssertFalse(owner.reenumerateDisplays())
        XCTAssertEqual(
            owner.snapshot(),
            .failed(
                revision: UInt64.max,
                failure: .generationExhausted
            )
        )
        XCTAssertEqual(recorder.enumerationCount, 0)
        XCTAssertEqual(recorder.permissionObservationCount, 0)
    }

    private var mainDisplay: HostAgentRecoveryDisplay {
        HostAgentRecoveryDisplay(
            canonicalID: 1,
            pixelWidth: 2560,
            pixelHeight: 1440,
            originX: 0,
            originY: 0,
            rotationDegrees: 0,
            isMain: true
        )
    }

    private var secondaryDisplay: HostAgentRecoveryDisplay {
        HostAgentRecoveryDisplay(
            canonicalID: 2,
            pixelWidth: 1920,
            pixelHeight: 1080,
            originX: 2560,
            originY: 0,
            rotationDegrees: 0,
            isMain: false
        )
    }

    private func grantedPermissions(
        inputMonitoring: Bool = true
    ) -> HostAgentRecoveryPermissionSnapshot {
        HostAgentRecoveryPermissionSnapshot(
            screenCaptureGranted: true,
            accessibilityGranted: true,
            inputMonitoringGranted: inputMonitoring
        )
    }

    private func makeOwner(
        recorder: DisplayTCCRecoveryRecorder
    ) -> HostAgentDisplayTCCRecoveryOwner {
        HostAgentDisplayTCCRecoveryOwner(
            operations: recorder.operations()
        )
    }
}

private final class DisplayTCCRecoveryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var inventories: [[HostAgentRecoveryDisplay]?]
    private let permissions: HostAgentRecoveryPermissionSnapshot
    private var storedEnumerationCount = 0
    private var storedPermissionObservationCount = 0
    var onEnumerate: (@Sendable () -> Void)?

    init(
        inventories: [[HostAgentRecoveryDisplay]?],
        permissions: HostAgentRecoveryPermissionSnapshot
    ) {
        self.inventories = inventories
        self.permissions = permissions
    }

    var enumerationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedEnumerationCount
    }

    var permissionObservationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPermissionObservationCount
    }

    func operations() -> HostAgentDisplayTCCRecoveryOperations {
        HostAgentDisplayTCCRecoveryOperations(
            enumerateDisplays: { [self] in enumerate() },
            observePermissions: { [self] in observePermissions() }
        )
    }

    private func enumerate() -> [HostAgentRecoveryDisplay]? {
        lock.lock()
        storedEnumerationCount += 1
        let inventory = inventories.isEmpty ? nil : inventories.removeFirst()
        let callback = onEnumerate
        lock.unlock()
        callback?()
        return inventory
    }

    private func observePermissions() -> HostAgentRecoveryPermissionSnapshot {
        lock.lock()
        storedPermissionObservationCount += 1
        let result = permissions
        lock.unlock()
        return result
    }
}

private final class DisplayTCCRecoveryOwnerBox: @unchecked Sendable {
    weak var owner: HostAgentDisplayTCCRecoveryOwner?
}
