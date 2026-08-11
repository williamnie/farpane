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

    func testClipboardPolicyChangesRequireInteractiveHostOffAndNoViewerStart() {
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy
                .allowsClipboardPolicyChange(
                    control: HostAgentBackgroundHomeControlState(
                        isOn: false,
                        isInteractive: true
                    ),
                    viewerConnectionInProgress: false
                )
        )
        for (control, viewerConnectionInProgress) in [
            (
                HostAgentBackgroundHomeControlState(
                    isOn: true,
                    isInteractive: true
                ),
                false
            ),
            (
                HostAgentBackgroundHomeControlState(
                    isOn: false,
                    isInteractive: false
                ),
                false
            ),
            (
                HostAgentBackgroundHomeControlState(
                    isOn: false,
                    isInteractive: true
                ),
                true
            ),
        ] {
            XCTAssertFalse(
                HostAgentBackgroundHomeRoutingPolicy
                    .allowsClipboardPolicyChange(
                        control: control,
                        viewerConnectionInProgress:
                            viewerConnectionInProgress
                    )
            )
        }
    }

    func testFileTransferPolicyChangesUseTheSameHostOffGate() {
        let allowed = HostAgentBackgroundHomeControlState(
            isOn: false,
            isInteractive: true
        )
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy
                .allowsFileTransferPolicyChange(
                    control: allowed,
                    viewerConnectionInProgress: false
                )
        )
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy
                .allowsFileTransferPolicyChange(
                    control: HostAgentBackgroundHomeControlState(
                        isOn: true,
                        isInteractive: true
                    ),
                    viewerConnectionInProgress: false
                )
        )
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy
                .allowsFileTransferPolicyChange(
                    control: allowed,
                    viewerConnectionInProgress: true
                )
        )
    }

    func testHostEnableRequiresPublishedBootstrapButDisableRemainsAvailable() {
        let off = HostAgentBackgroundHomeControlState(
            isOn: false,
            isInteractive: true
        )
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: off,
                bootstrapReady: false
            )
        )
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: off,
                bootstrapReady: true
            )
        )
        XCTAssertTrue(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: HostAgentBackgroundHomeControlState(
                    isOn: true,
                    isInteractive: true
                ),
                bootstrapReady: false
            )
        )
        XCTAssertFalse(
            HostAgentBackgroundHomeRoutingPolicy.allowsHostToggle(
                control: HostAgentBackgroundHomeControlState(
                    isOn: true,
                    isInteractive: false
                ),
                bootstrapReady: true
            )
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

    func testClipboardPolicyUIAndBothHostOwnersUseOneExplicitProjection() throws {
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
        let agentSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
            ),
            encoding: .utf8
        )

        for marker in [
            "farpane.host.clipboard.allowRemoteRead",
            "farpane.host.clipboard.allowRemoteWrite",
            "farpane.host.clipboard.richText.allowRemoteRead",
            "farpane.host.clipboard.richText.allowRemoteWrite",
            "farpane.host.clipboard.image.allowRemoteRead",
            "farpane.host.clipboard.image.allowRemoteWrite",
            "clipboardPolicy: currentHostClipboardPolicy()",
            "clipboardReadEnabled: clipboardPolicy.allowRemoteRead",
            "clipboardWriteEnabled: clipboardPolicy.allowRemoteWrite",
            "clipboardRichTextReadEnabled:",
            "clipboardPolicy.allowRemoteRichTextRead",
            "clipboardRichTextWriteEnabled:",
            "clipboardPolicy.allowRemoteRichTextWrite",
            "clipboardImageReadEnabled:",
            "clipboardPolicy.allowRemoteImageRead",
            "clipboardImageWriteEnabled:",
            "clipboardPolicy.allowRemoteImageWrite",
            "allowsClipboardPolicyChange(",
        ] {
            XCTAssertTrue(appSource.contains(marker), marker)
        }
        for marker in [
            "允许远端读取本机剪贴板",
            "允许远端写入本机剪贴板",
            "允许远端读取本机富文本",
            "允许远端写入本机富文本",
            "允许远端读取本机图片",
            "允许远端写入图片到本机",
            "onHostClipboardReadToggle",
            "onHostClipboardWriteToggle",
            "onHostClipboardRichTextReadToggle",
            "onHostClipboardRichTextWriteToggle",
            "onHostClipboardImageReadToggle",
            "onHostClipboardImageWriteToggle",
            "snapshot.host.allowsClipboardPolicyChange",
        ] {
            XCTAssertTrue(homeSource.contains(marker), marker)
        }
        XCTAssertTrue(agentSource.contains(
            "configuration.clipboardPolicy.allowRemoteRead"
        ))
        XCTAssertTrue(agentSource.contains(
            "configuration.clipboardPolicy.allowRemoteWrite"
        ))
        XCTAssertTrue(agentSource.contains(
            ".allowRemoteRichTextRead"
        ))
        XCTAssertTrue(agentSource.contains(
            ".allowRemoteRichTextWrite"
        ))
        XCTAssertTrue(agentSource.contains(
            ".allowRemoteImageRead"
        ))
        XCTAssertTrue(agentSource.contains(
            ".allowRemoteImageWrite"
        ))
    }

    func testFileTransferHomeOptInUsesOnePolicyForBothHostOwners() throws {
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
        let agentSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
            ),
            encoding: .utf8
        )

        for marker in [
            "farpane.host.fileTransfer.enabled",
            "farpane.host.fileTransfer.receiveRoot",
            "fileTransferPolicy: currentHostFileTransferPolicy()",
            "fileTransferEnabled: fileTransferPolicy.enabled",
            "fileTransferReceiveRoot: fileTransferPolicy.receiveRoot",
            "allowsFileTransferPolicyChange(",
            "HostFileTransferReceiveRootPickerController",
        ] {
            XCTAssertTrue(appSource.contains(marker), marker)
        }
        for marker in [
            "文件接收（默认关闭）",
            "FarPane Receive",
            "onHostFileTransferToggle",
            "onChooseHostFileTransferReceiveRoot",
            "snapshot.host.allowsFileTransferPolicyChange",
        ] {
            XCTAssertTrue(homeSource.contains(marker), marker)
        }
        XCTAssertTrue(agentSource.contains(
            "configuration.fileTransferPolicy.enabled"
        ))
        XCTAssertTrue(agentSource.contains(
            "configuration.fileTransferPolicy.receiveRoot"
        ))
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
