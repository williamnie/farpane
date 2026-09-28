import Foundation
import XCTest

@testable import CoreBridge

final class HostAgentBackgroundHomeRoutingPolicyTests: XCTestCase {
    func testControlStateUsesAuthoritativeBackgroundOrLegacyIntent() {
        XCTAssertEqual(
            controlState(.notRegistered, .eligible),
            HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true))
        XCTAssertEqual(
            controlState(.notRegistered, .blocked([.preferenceEnabled, .runtimeActive])),
            HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true))
        for registration in [HostAgentBackgroundRegistrationStatus.enabled, .requiresApproval] {
            XCTAssertEqual(
                controlState(registration, .eligible),
                HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true))
        }
    }

    func testConflictingOwnershipAndInFlightStatesAreNotInteractive() {
        XCTAssertEqual(
            controlState(.enabled, .blocked([.runtimeActive])),
            HostAgentBackgroundHomeControlState(isOn: true, isInteractive: false))
        XCTAssertEqual(
            controlState(.notRegistered, .failed(.evidenceUnavailable)),
            HostAgentBackgroundHomeControlState(isOn: false, isInteractive: false))
        XCTAssertEqual(
            controlState(.notRegistered, .eligible, flow: .registration),
            HostAgentBackgroundHomeControlState(isOn: false, isInteractive: false))
    }

    func testToggleRoutesDoNotConflateLegacyAndBackgroundOwnership() {
        XCTAssertEqual(
            toggleRoute(false, .notRegistered, .blocked([.preferenceEnabled, .runtimeActive])),
            .stopLegacyHost)
        XCTAssertEqual(toggleRoute(true, .notRegistered, .eligible), .beginRegistration)
        XCTAssertEqual(toggleRoute(false, .enabled, .eligible), .beginUnregistration)
        XCTAssertEqual(toggleRoute(false, .requiresApproval, .eligible), .beginUnregistration)
    }

    func testReplacedAppCanExplicitlyRestoreMissingServiceRegistration() {
        let residualPreference = HostAgentLegacyHostMigrationAssessment.blocked([.preferenceEnabled]
        )
        XCTAssertEqual(
            controlState(.serviceUnavailable, residualPreference),
            HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true))
        XCTAssertEqual(
            toggleRoute(true, .serviceUnavailable, residualPreference), .beginRegistration)

        let activeLegacyHost = HostAgentLegacyHostMigrationAssessment.blocked([
            .preferenceEnabled, .runtimeActive,
        ])
        XCTAssertEqual(
            controlState(.serviceUnavailable, activeLegacyHost),
            HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true))
        XCTAssertEqual(toggleRoute(false, .serviceUnavailable, activeLegacyHost), .stopLegacyHost)
    }

    func testClipboardPolicyChangesRequireInteractiveHostOffAndNoViewerStart() {
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsClipboardPolicyChange(
                control: HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true),
                viewerConnectionInProgress: false))
        for (control, viewerConnectionInProgress) in [
            (HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true), false),
            (HostAgentBackgroundHomeControlState(isOn: false, isInteractive: false), false),
            (HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true), true),
        ] {
            XCTAssertFalse(
                HostAgentBackgroundHomeRoutingPolicy.allowsClipboardPolicyChange(
                    control: control, viewerConnectionInProgress: viewerConnectionInProgress))
        }
    }

    func testFileTransferPolicyChangesUseTheSameHostOffGate() {
        let allowed = HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true)
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsFileTransferPolicyChange(
                control: allowed, viewerConnectionInProgress: false))
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsFileTransferPolicyChange(
                control: HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true),
                viewerConnectionInProgress: false))
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsFileTransferPolicyChange(
                control: allowed, viewerConnectionInProgress: true))
    }

    func testAudioPolicyChangesRequireHostOffNoViewerAndNoAuthorizationRequest() {
        let allowed = HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true)
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsAudioPolicyChange(
                control: allowed, viewerConnectionInProgress: false,
                authorizationRequestInProgress: false))
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsAudioPolicyChange(
                control: HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true),
                viewerConnectionInProgress: false, authorizationRequestInProgress: false))
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsAudioPolicyChange(
                control: allowed, viewerConnectionInProgress: true,
                authorizationRequestInProgress: false))
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsAudioPolicyChange(
                control: allowed, viewerConnectionInProgress: false,
                authorizationRequestInProgress: true))
    }

    func testHostEnableRequiresPublishedBootstrapButDisableRemainsAvailable() {
        let off = HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true)
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: off, bootstrapReady: false))
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: off, bootstrapReady: true))
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: HostAgentBackgroundHomeControlState(isOn: true, isInteractive: true),
                bootstrapReady: false))
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: HostAgentBackgroundHomeControlState(isOn: true, isInteractive: false),
                bootstrapReady: true))
    }

    func testConfiguredEligibleProductAutomaticallyRegistersOncePerLaunch() {
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.shouldAutomaticallyRegister(
                registration: .notRegistered, legacy: .eligible, bootstrapReady: true,
                alreadyAttempted: false))
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.shouldAutomaticallyRegister(
                registration: .serviceUnavailable, legacy: .eligible, bootstrapReady: true,
                alreadyAttempted: false))
    }

    func testAutomaticRegistrationDoesNotLoopOrOverrideUnsafeOwnership() {
        let blockedCases:
            [(
                HostAgentBackgroundRegistrationStatus, HostAgentLegacyHostMigrationAssessment, Bool,
                Bool
            )] = [
                (.enabled, .eligible, true, false), (.requiresApproval, .eligible, true, false),
                (.notRegistered, .eligible, false, false), (.notRegistered, .eligible, true, true),
                (.notRegistered, .blocked([.runtimeActive]), true, false),
                (.notRegistered, .failed(.evidenceUnavailable), true, false),
            ]
        for (registration, legacy, bootstrapReady, alreadyAttempted) in blockedCases {
            XCTAssertFalse(
                HostAgentBackgroundHomeRoutingPolicy.shouldAutomaticallyRegister(
                    registration: registration, legacy: legacy, bootstrapReady: bootstrapReady,
                    alreadyAttempted: alreadyAttempted))
        }
    }

    func testToggleRoutesIgnoreNoopUnknownConflictAndInFlightRequests() {
        let routes: [HostAgentBackgroundHomeToggleRoute] = [
            toggleRoute(false, .notRegistered, .eligible), toggleRoute(true, .enabled, .eligible),
            toggleRoute(false, .enabled, .blocked([.runtimeActive])),
            toggleRoute(true, .notRegistered, .eligible, flow: .registration),
        ]
        XCTAssertEqual(routes, Array(repeating: .noAction, count: 4))
    }

    func testResidualLegacyOwnershipCanEnterConfirmedMigrationFlow() {
        let assessment = HostAgentLegacyHostMigrationAssessment.blocked([.clientRetained])
        XCTAssertEqual(
            controlState(.notRegistered, assessment),
            HostAgentBackgroundHomeControlState(isOn: false, isInteractive: true))
        XCTAssertEqual(toggleRoute(true, .notRegistered, assessment), .beginRegistration)
    }

    func testLaunchRoutingNeverStartsLegacyWhenBackgroundMayOwnHost() {
        XCTAssertEqual(
            launchRoute(.notRegistered, .blocked([.preferenceEnabled])), .preserveLegacyHost)
        XCTAssertEqual(launchRoute(.notRegistered, .eligible), .hold)
        XCTAssertEqual(launchRoute(.enabled, .eligible), .observeBackground)
        XCTAssertEqual(
            launchRoute(.requiresApproval, .blocked([.preferenceEnabled, .runtimeActive])),
            .quiesceLegacyThenObserveBackground)
        XCTAssertEqual(launchRoute(.serviceUnavailable, .blocked([.preferenceEnabled])), .hold)
        XCTAssertEqual(launchRoute(.notRegistered, .failed(.evidenceUnavailable)), .hold)
    }

}

private func controlState(
    _ registration: HostAgentBackgroundRegistrationStatus,
    _ legacy: HostAgentLegacyHostMigrationAssessment, flow: HostAgentBackgroundHomeFlow? = nil
) -> HostAgentBackgroundHomeControlState {
    HostAgentBackgroundHomeRoutingPolicy.controlState(
        registration: registration, legacy: legacy, flow: flow)
}

private func toggleRoute(
    _ requestedEnabled: Bool, _ registration: HostAgentBackgroundRegistrationStatus,
    _ legacy: HostAgentLegacyHostMigrationAssessment, flow: HostAgentBackgroundHomeFlow? = nil
) -> HostAgentBackgroundHomeToggleRoute {
    HostAgentBackgroundHomeRoutingPolicy.toggleRoute(
        requestedEnabled: requestedEnabled, registration: registration, legacy: legacy, flow: flow)
}

private func launchRoute(
    _ registration: HostAgentBackgroundRegistrationStatus,
    _ legacy: HostAgentLegacyHostMigrationAssessment
) -> HostAgentBackgroundHomeLaunchRoute {
    HostAgentBackgroundHomeRoutingPolicy.launchRoute(registration: registration, legacy: legacy)
}
