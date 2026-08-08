@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundHomeRoutingPolicyTests: XCTestCase {
    func testControlStateUsesAuthoritativeBackgroundOrLegacyIntent() {
        XCTAssertEqual(
            controlState(.notRegistered, .eligible),
            HostAgentBackgroundHomeControlState(
                isOn: false,
                isInteractive: true
            )
        )
        XCTAssertEqual(
            controlState(
                .notRegistered,
                .blocked([.preferenceEnabled, .runtimeActive])
            ),
            HostAgentBackgroundHomeControlState(
                isOn: true,
                isInteractive: true
            )
        )
        for registration in [
            HostAgentBackgroundRegistrationStatus.enabled,
            .requiresApproval,
        ] {
            XCTAssertEqual(
                controlState(registration, .eligible),
                HostAgentBackgroundHomeControlState(
                    isOn: true,
                    isInteractive: true
                )
            )
        }
    }

    func testUnknownConflictAndInFlightStatesAreNotInteractive() {
        XCTAssertEqual(
            controlState(
                .serviceUnavailable,
                .blocked([.preferenceEnabled])
            ),
            HostAgentBackgroundHomeControlState(
                isOn: true,
                isInteractive: false
            )
        )
        XCTAssertEqual(
            controlState(
                .enabled,
                .blocked([.runtimeActive])
            ),
            HostAgentBackgroundHomeControlState(
                isOn: true,
                isInteractive: false
            )
        )
        XCTAssertEqual(
            controlState(
                .notRegistered,
                .failed(.evidenceUnavailable)
            ),
            HostAgentBackgroundHomeControlState(
                isOn: false,
                isInteractive: false
            )
        )
        XCTAssertEqual(
            controlState(
                .notRegistered,
                .eligible,
                flow: .registration
            ),
            HostAgentBackgroundHomeControlState(
                isOn: false,
                isInteractive: false
            )
        )
    }

    func testToggleRoutesDoNotConflateLegacyAndBackgroundOwnership() {
        XCTAssertEqual(
            toggleRoute(
                false,
                .notRegistered,
                .blocked([.preferenceEnabled, .runtimeActive])
            ),
            .stopLegacyHost
        )
        XCTAssertEqual(
            toggleRoute(true, .notRegistered, .eligible),
            .beginRegistration
        )
        XCTAssertEqual(
            toggleRoute(false, .enabled, .eligible),
            .beginUnregistration
        )
        XCTAssertEqual(
            toggleRoute(false, .requiresApproval, .eligible),
            .beginUnregistration
        )
    }

    func testToggleRoutesIgnoreNoopUnknownConflictAndInFlightRequests() {
        let routes: [HostAgentBackgroundHomeToggleRoute] = [
            toggleRoute(false, .notRegistered, .eligible),
            toggleRoute(true, .enabled, .eligible),
            toggleRoute(
                true,
                .serviceUnavailable,
                .eligible
            ),
            toggleRoute(
                false,
                .enabled,
                .blocked([.runtimeActive])
            ),
            toggleRoute(
                true,
                .notRegistered,
                .eligible,
                flow: .registration
            ),
        ]
        XCTAssertEqual(routes, Array(repeating: .noAction, count: 5))
    }

    func testResidualLegacyOwnershipCanEnterConfirmedMigrationFlow() {
        let assessment = HostAgentLegacyHostMigrationAssessment.blocked([
            .clientRetained,
        ])
        XCTAssertEqual(
            controlState(.notRegistered, assessment),
            HostAgentBackgroundHomeControlState(
                isOn: false,
                isInteractive: true
            )
        )
        XCTAssertEqual(
            toggleRoute(true, .notRegistered, assessment),
            .beginRegistration
        )
    }

    func testLaunchRoutingNeverStartsLegacyWhenBackgroundMayOwnHost() {
        XCTAssertEqual(
            launchRoute(
                .notRegistered,
                .blocked([.preferenceEnabled])
            ),
            .preserveLegacyHost
        )
        XCTAssertEqual(
            launchRoute(.notRegistered, .eligible),
            .hold
        )
        XCTAssertEqual(
            launchRoute(.enabled, .eligible),
            .observeBackground
        )
        XCTAssertEqual(
            launchRoute(
                .requiresApproval,
                .blocked([.preferenceEnabled, .runtimeActive])
            ),
            .quiesceLegacyThenObserveBackground
        )
        XCTAssertEqual(
            launchRoute(
                .serviceUnavailable,
                .blocked([.preferenceEnabled])
            ),
            .hold
        )
        XCTAssertEqual(
            launchRoute(
                .notRegistered,
                .failed(.evidenceUnavailable)
            ),
            .hold
        )
    }

    func testAppAndHomeUseOneProductRouteWithoutLegacyFallback() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )
        let homeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HomeView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(appSource.contains(
            "view.onHostToggle = { [weak self] enabled in\n"
                + "            self?.handleHostProductToggle(enabled)\n"
                + "        }"
        ))
        XCTAssertFalse(appSource.contains(
            "self?.setHostModeEnabled(enabled)"
        ))
        XCTAssertFalse(appSource.contains(
            "private func setHostModeEnabled(_ enabled: Bool)"
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundHomeRoutingPolicy.launchRoute("
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundHomeRoutingPolicy.toggleRoute("
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundHomeRoutingPolicy.controlState("
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundActivationOwner.refreshRegistration()"
        ))
        XCTAssertTrue(homeSource.contains(
            "var isControlEnabled: Bool"
        ))
        XCTAssertTrue(homeSource.contains(
            "&& snapshot.host.isControlEnabled"
        ))
        XCTAssertEqual(appSource.components(
            separatedBy: "beginHostAgentBackgroundRegistration()"
        ).count - 1, 2)
        XCTAssertEqual(appSource.components(
            separatedBy: "beginHostAgentBackgroundUnregistration()"
        ).count - 1, 2)
    }
}

private func controlState(
    _ registration: HostAgentBackgroundRegistrationStatus,
    _ legacy: HostAgentLegacyHostMigrationAssessment,
    flow: HostAgentBackgroundHomeFlow? = nil
) -> HostAgentBackgroundHomeControlState {
    HostAgentBackgroundHomeRoutingPolicy.controlState(
        registration: registration,
        legacy: legacy,
        flow: flow
    )
}

private func toggleRoute(
    _ requestedEnabled: Bool,
    _ registration: HostAgentBackgroundRegistrationStatus,
    _ legacy: HostAgentLegacyHostMigrationAssessment,
    flow: HostAgentBackgroundHomeFlow? = nil
) -> HostAgentBackgroundHomeToggleRoute {
    HostAgentBackgroundHomeRoutingPolicy.toggleRoute(
        requestedEnabled: requestedEnabled,
        registration: registration,
        legacy: legacy,
        flow: flow
    )
}

private func launchRoute(
    _ registration: HostAgentBackgroundRegistrationStatus,
    _ legacy: HostAgentLegacyHostMigrationAssessment
) -> HostAgentBackgroundHomeLaunchRoute {
    HostAgentBackgroundHomeRoutingPolicy.launchRoute(
        registration: registration,
        legacy: legacy
    )
}
