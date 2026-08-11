import XCTest
@testable import CoreBridge

final class ViewerAudioSessionOwnerTests: XCTestCase {
    func testDefaultOffOwnerIgnoresRemotePermission() {
        let owner = ViewerAudioSessionOwner(receiveAudio: false)

        XCTAssertEqual(owner.snapshot().phase, .disabled)
        XCTAssertFalse(owner.observe(permission(epoch: 1, enabled: true)))
        XCTAssertEqual(owner.snapshot().phase, .disabled)
        XCTAssertNil(owner.snapshot().connectionEpoch)
    }

    func testOptInTracksDeniedReceivingRevokedAndRegrant() {
        let owner = ViewerAudioSessionOwner(receiveAudio: true)

        XCTAssertEqual(owner.snapshot().phase, .awaitingRemotePermission)
        XCTAssertTrue(owner.observe(permission(epoch: 7, enabled: false)))
        XCTAssertEqual(owner.snapshot().phase, .deniedByRemote)
        XCTAssertTrue(owner.observe(permission(epoch: 7, enabled: true)))
        XCTAssertEqual(owner.snapshot().phase, .receiving)
        XCTAssertTrue(owner.observe(permission(epoch: 7, enabled: false)))
        XCTAssertEqual(owner.snapshot().phase, .revokedByRemote)
        XCTAssertTrue(owner.observe(permission(epoch: 7, enabled: true)))
        XCTAssertEqual(owner.snapshot().phase, .receiving)
    }

    func testEpochMismatchAndTerminalEventsFailClosed() {
        let owner = ViewerAudioSessionOwner(receiveAudio: true)

        XCTAssertTrue(owner.observe(permission(epoch: 9, enabled: true)))
        XCTAssertFalse(owner.observe(permission(epoch: 10, enabled: false)))
        XCTAssertEqual(owner.snapshot().phase, .receiving)
        owner.stop()
        XCTAssertEqual(owner.snapshot().phase, .ended)
        XCTAssertFalse(owner.observe(permission(epoch: 9, enabled: true)))
        XCTAssertEqual(owner.snapshot().phase, .ended)
    }

    func testPresentationDistinguishesEveryPolicyAndPermissionState() {
        let disabled = ViewerAudioSessionPresentationPolicy.project(
            ViewerAudioSessionOwner(receiveAudio: false).snapshot()
        )
        XCTAssertEqual(disabled.statusText, "音频：本次未开启")
        XCTAssertFalse(disabled.statusIsError)

        let owner = ViewerAudioSessionOwner(receiveAudio: true)
        XCTAssertEqual(
            ViewerAudioSessionPresentationPolicy.project(owner.snapshot()).statusText,
            "音频：等待远端授权"
        )
        XCTAssertTrue(owner.observe(permission(epoch: 3, enabled: false)))
        let denied = ViewerAudioSessionPresentationPolicy.project(owner.snapshot())
        XCTAssertEqual(denied.statusText, "音频：远端未授权")
        XCTAssertTrue(denied.statusIsError)
    }

    private func permission(epoch: UInt64, enabled: Bool) -> CoreRemotePermissionEvent {
        CoreRemotePermissionEvent(
            connectionEpoch: epoch,
            permission: .audio,
            enabled: enabled
        )
    }
}
