@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundProductRoutingPolicyTests: XCTestCase {
    func testRegistrationSuccessAndApprovalEnableAndRefreshObservation() {
        let views: [HostAgentBackgroundRegistrationUXView] = [
            registrationView(.registered, registration: .enabled),
            registrationView(
                .navigationRequested,
                registration: .requiresApproval
            ),
            registrationView(
                .approvalNoLongerRequired,
                registration: .enabled
            ),
            registrationView(.cancelled, registration: .requiresApproval),
        ]

        for view in views {
            XCTAssertEqual(
                HostAgentBackgroundProductRoutingPolicy.registrationDecision(
                    view
                ),
                .enableAndRefresh
            )
        }
    }

    func testRegistrationNonMutationTerminalsPreserveActivation() {
        let views: [HostAgentBackgroundRegistrationUXView] = [
            registrationView(.cancelled, registration: nil),
            registrationView(
                .migrationBlocked([.activeSession]),
                registration: nil
            ),
            registrationView(
                .failed(
                    .migration(.assessment(.evidenceUnavailable))
                ),
                registration: nil
            ),
            registrationView(
                .failed(
                    .registration(.invalidCodeSignature)
                ),
                registration: nil
            ),
            registrationView(
                .failed(
                    .registration(.registrationNotEffective)
                ),
                registration: .notRegistered
            ),
            registrationView(
                .failed(.registration(.serviceUnavailable)),
                registration: .serviceUnavailable
            ),
        ]

        for view in views {
            XCTAssertEqual(
                HostAgentBackgroundProductRoutingPolicy.registrationDecision(
                    view
                ),
                .noChange
            )
        }
    }

    func testRegistrationObservationThatBecameNotRegisteredDisables() {
        XCTAssertEqual(
            HostAgentBackgroundProductRoutingPolicy.registrationDecision(
                registrationView(
                    .approvalNoLongerRequired,
                    registration: .notRegistered
                )
            ),
            .disable
        )
    }

    func testRegistrationContradictionsAndNonterminalsFailClosed() {
        let views: [HostAgentBackgroundRegistrationUXView] = [
            registrationView(.idle, registration: nil),
            registrationView(.preparingLegacyHost, registration: nil),
            registrationView(.registering, registration: nil),
            registrationView(.registered, registration: .requiresApproval),
            registrationView(
                .navigationRequested,
                registration: .enabled
            ),
            registrationView(
                .migrationBlocked([.activeSession]),
                registration: .enabled
            ),
            registrationView(
                .failed(.invalidRegistrationResult),
                registration: .enabled
            ),
            registrationView(
                .failed(
                    .registration(.unregistrationNotEffective)
                ),
                registration: .enabled
            ),
        ]

        for view in views {
            XCTAssertEqual(
                HostAgentBackgroundProductRoutingPolicy.registrationDecision(
                    view
                ),
                .invalidCompletion
            )
        }
    }

    func testUnregistrationOnlyExactAuthoritativeSuccessDisables() {
        XCTAssertEqual(
            HostAgentBackgroundProductRoutingPolicy
                .unregistrationDecision(unregistrationView(
                    .unregistered,
                    registration: .notRegistered
                )),
            .disable
        )

        let noChanges: [HostAgentBackgroundUnregistrationUXView] = [
            unregistrationView(.cancelled, registration: nil),
            unregistrationView(
                .failed(.mutation(.serviceUnavailable)),
                registration: .serviceUnavailable
            ),
            unregistrationView(
                .failed(.mutation(.unregistrationNotEffective)),
                registration: .enabled
            ),
            unregistrationView(
                .failed(.mutation(.unregistrationNotEffective)),
                registration: .requiresApproval
            ),
        ]
        for view in noChanges {
            XCTAssertEqual(
                HostAgentBackgroundProductRoutingPolicy
                    .unregistrationDecision(view),
                .noChange
            )
        }
    }

    func testUnregistrationContradictionsAndNonterminalsFailClosed() {
        let views: [HostAgentBackgroundUnregistrationUXView] = [
            unregistrationView(.idle, registration: nil),
            unregistrationView(.unregistering, registration: nil),
            unregistrationView(.unregistered, registration: .enabled),
            unregistrationView(.cancelled, registration: .enabled),
            unregistrationView(
                .failed(.mutation(.registrationNotEffective)),
                registration: .notRegistered
            ),
            unregistrationView(
                .failed(.invalidMutationResult),
                registration: .enabled
            ),
        ]

        for view in views {
            XCTAssertEqual(
                HostAgentBackgroundProductRoutingPolicy
                    .unregistrationDecision(view),
                .invalidCompletion
            )
        }
    }

    func testAppOwnsDedicatedMainActorRoutingButHomeIsNotSwitchedYet() throws {
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
            "private lazy var hostAgentBackgroundActivationOwner"
        ))
        XCTAssertTrue(appSource.contains(
            "private func beginHostAgentBackgroundRegistration()"
        ))
        XCTAssertTrue(appSource.contains(
            "private func beginHostAgentBackgroundUnregistration()"
        ))
        XCTAssertEqual(appSource.components(
            separatedBy: "hostAgentBackgroundRegistrationSheetDriver.begin("
        ).count - 1, 1)
        XCTAssertEqual(appSource.components(
            separatedBy: "hostAgentBackgroundUnregistrationSheetDriver.begin("
        ).count - 1, 1)
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundProductRoutingPolicy.registrationDecision("
        ))
        XCTAssertTrue(appSource.contains(
            "HostAgentBackgroundProductRoutingPolicy.unregistrationDecision("
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundActivationOwner.refreshRegistration()"
        ))
        XCTAssertTrue(appSource.contains(
            "hostAgentBackgroundActivationOwner.apply(\n"
                + "            .applicationWillTerminate"
        ))
        XCTAssertTrue(appSource.contains(
            "view.onHostToggle = { [weak self] enabled in "
                + "self?.setHostModeEnabled(enabled) }"
        ))
        XCTAssertFalse(homeSource.contains(
            "beginHostAgentBackgroundRegistration"
        ))
        XCTAssertFalse(homeSource.contains(
            "beginHostAgentBackgroundUnregistration"
        ))
    }
}

private func registrationView(
    _ phase: HostAgentBackgroundRegistrationUXPhase,
    registration: HostAgentBackgroundRegistrationStatus?
) -> HostAgentBackgroundRegistrationUXView {
    HostAgentBackgroundRegistrationUXView(
        generation: 1,
        phase: phase,
        registration: registration
    )
}

private func unregistrationView(
    _ phase: HostAgentBackgroundUnregistrationUXPhase,
    registration: HostAgentBackgroundRegistrationStatus?
) -> HostAgentBackgroundUnregistrationUXView {
    HostAgentBackgroundUnregistrationUXView(
        generation: 1,
        phase: phase,
        registration: registration
    )
}
