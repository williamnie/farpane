import Foundation
import XCTest

final class HostAgentDisplayTCCRecoveryAuthorityContractTests: XCTestCase {
    func testProductAuthorityUsesOnlyNonPromptingMacOSObservations() throws {
        let source = try productSource(
            "HostAgentDisplayTCCRecoveryAuthority.swift"
        )

        XCTAssertTrue(source.contains("CGGetActiveDisplayList("))
        XCTAssertTrue(source.contains("CGMainDisplayID()"))
        XCTAssertTrue(source.contains("CGDisplayPixelsWide("))
        XCTAssertTrue(source.contains("CGDisplayPixelsHigh("))
        XCTAssertTrue(source.contains("CGDisplayBounds("))
        XCTAssertTrue(source.contains("CGDisplayRotation("))
        XCTAssertTrue(source.contains("CGPreflightScreenCaptureAccess()"))
        XCTAssertTrue(source.contains("AXIsProcessTrustedWithOptions("))
        XCTAssertTrue(source.contains("CGPreflightListenEventAccess()"))
        XCTAssertTrue(source.contains(
            "kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false"
        ))
        XCTAssertFalse(source.contains("CGRequestScreenCaptureAccess()"))
        XCTAssertFalse(source.contains("CGRequestListenEventAccess()"))
        XCTAssertFalse(source.contains("NSWorkspace"))
        XCTAssertFalse(source.contains("NSAlert"))
    }

    func testCompositionHardBindsDisplayTCCAuthorityAndCancelsItLast() throws {
        let source = try productSource(
            "HostAgentSleepWakeRecoveryComposition.swift"
        )

        XCTAssertTrue(source.contains(
            "displayTCCAuthority.reenumerateDisplays()"
        ))
        XCTAssertTrue(source.contains(
            "displayTCCAuthority.revalidatePermissions()"
        ))
        XCTAssertTrue(source.contains("displayTCCAuthority.snapshot()"))
        XCTAssertFalse(source.contains("let reenumerateDisplays: @Sendable"))
        XCTAssertFalse(source.contains("let revalidatePermissions: @Sendable"))
        let recoveryCancel = try XCTUnwrap(source.range(of: "owner.cancel()"))
        let environmentCancel = try XCTUnwrap(source.range(
            of: "displayTCCAuthority.cancel()"
        ))
        let registrationCancel = try XCTUnwrap(source.range(
            of: "registrationRecoveryOwner.cancelAndWait()"
        ))
        XCTAssertLessThan(
            recoveryCancel.lowerBound,
            registrationCancel.lowerBound
        )
        XCTAssertLessThan(
            registrationCancel.lowerBound,
            environmentCancel.lowerBound
        )
    }

    private func productSource(_ name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Sources/RustDeskNative")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
