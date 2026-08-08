@testable import CoreBridge
import Foundation
import XCTest

final class HostAgentBackgroundRegistrationSheetDriverTests: XCTestCase {
    func testMapsEveryPromptResponseToOneMatchingTypedIntent() {
        let expected: [(
            HostAgentBackgroundRegistrationUXPromptKind,
            Bool,
            HostAgentBackgroundRegistrationUXIntent
        )] = [
            (
                .backgroundPersistence,
                true,
                .confirmBackgroundRegistration
            ),
            (
                .backgroundPersistence,
                false,
                .cancelBackgroundRegistration
            ),
            (
                .loginItemsApproval,
                true,
                .confirmApprovalNavigation
            ),
            (
                .loginItemsApproval,
                false,
                .cancelApprovalNavigation
            ),
        ]

        for (kind, confirmed, intent) in expected {
            XCTAssertEqual(
                HostAgentBackgroundRegistrationSheetResponsePolicy.intent(
                    promptKind: kind,
                    confirmed: confirmed
                ),
                intent
            )
        }
    }

    func testProductDriverUsesNonblockingSingleSheetAndTypedPolicy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/HostAgentBackgroundRegistrationSheetDriver.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("import AppKit"))
        XCTAssertTrue(source.contains("import CoreBridge"))
        XCTAssertTrue(source.contains(
            "HostAgentBackgroundRegistrationUXOwner.makeProduct(\n"
                + "                performMigrationPreparation: "
                + "performMigrationPreparation"
        ))
        XCTAssertFalse(source.contains(
            "static func makeProduct(\n"
                + "        onUpdate:"
        ))
        XCTAssertTrue(source.contains("Thread.isMainThread"))
        XCTAssertTrue(source.contains("let alert = NSAlert()"))
        XCTAssertTrue(source.contains("alert.messageText = prompt.title"))
        XCTAssertTrue(source.contains(
            "alert.informativeText = prompt.message"
        ))
        XCTAssertTrue(source.contains(
            "alert.addButton(withTitle: prompt.confirmButtonTitle)"
        ))
        XCTAssertTrue(source.contains(
            "alert.addButton(withTitle: prompt.cancelButtonTitle)"
        ))
        XCTAssertTrue(source.contains("alert.beginSheetModal(for: window)"))
        XCTAssertTrue(source.contains(
            "HostAgentBackgroundRegistrationSheetResponsePolicy.intent("
        ))
        XCTAssertTrue(source.contains("activePresentationToken == token"))
        XCTAssertTrue(source.contains("current.generation == generation"))
        XCTAssertTrue(source.contains("DispatchQueue.main.async"))
        XCTAssertFalse(source.contains("runModal"))
        XCTAssertFalse(source.contains("SMAppService"))
        XCTAssertFalse(source.contains("UserDefaults"))
        XCTAssertFalse(source.contains("HostControlClient"))
        XCTAssertFalse(source.contains("HostAgentBackgroundActivationOwner"))
        XCTAssertFalse(source.contains("onHostToggle"))
        XCTAssertFalse(source.contains("setHostModeEnabled"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    func testDriverIsLazilyComposedButHasNoBeginCallSite() throws {
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
            "private lazy var hostAgentBackgroundRegistrationSheetDriver"
        ))
        XCTAssertFalse(appSource.contains(
            "hostAgentBackgroundRegistrationSheetDriver.begin("
        ))
        XCTAssertFalse(homeSource.contains(
            "HostAgentBackgroundRegistrationSheetDriver"
        ))
    }
}
