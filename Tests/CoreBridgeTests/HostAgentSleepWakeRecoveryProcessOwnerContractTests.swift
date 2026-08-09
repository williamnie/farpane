import Foundation
import XCTest

final class HostAgentSleepWakeRecoveryProcessOwnerContractTests: XCTestCase {
    func testProcessOwnerHardBindsProjectionAndProductEnvironment() throws {
        let owner = try productSource(
            "HostAgentSleepWakeRecoveryProcessOwner.swift"
        )
        let composition = try productSource(
            "HostAgentSleepWakeRecoveryComposition.swift"
        )

        XCTAssertTrue(owner.contains(
            "HostAgentDisplayTCCRecoveryAuthority.makeProduct()"
        ))
        XCTAssertTrue(owner.contains(
            "snapshotCoordinator.publishRecoverySnapshot("
        ))
        XCTAssertTrue(owner.contains("recoveryStatus: .suspending"))
        XCTAssertTrue(owner.contains("registrationStatus: \"suspending\""))
        XCTAssertTrue(owner.contains("recoveryStatus: .running"))
        XCTAssertTrue(owner.contains("registrationStatus: \"ready\""))
        XCTAssertTrue(owner.contains(
            "recoveryEvidenceOwner.acceptSleepWake("
        ))
        XCTAssertTrue(owner.contains(
            "recoveryEvidenceOwner.recordSleepWakeCompleted("
        ))
        let installStart = try XCTUnwrap(owner.range(of: "func install("))
        let installTail = owner[installStart.lowerBound...]
        let installSignatureEnd = try XCTUnwrap(installTail.range(of: ") -> Bool"))
        let installSignature = installTail[..<installSignatureEnd.upperBound]
        XCTAssertFalse(installSignature.contains("operations:"))
        XCTAssertTrue(installSignature.contains(
            "recoveryEvidenceOwner: HostRecoveryTransitionEvidenceProcessOwner"
        ))
        XCTAssertTrue(owner.contains(
            "HostAgentNSWorkspaceSleepWakeIngress.makeProduct("
        ))
        XCTAssertFalse(owner.contains("import AppKit"))

        XCTAssertGreaterThanOrEqual(
            composition.components(separatedBy: "[weak lifetime]").count - 1,
            4
        )
    }

    func testProcessInstallsAfterMediaAndCancelsBeforeRuntimeResources() throws {
        let process = try productSource("HostAgentProcess.swift")

        XCTAssertTrue(process.contains(
            "HostAgentSleepWakeRecoveryProcessOwner()"
        ))
        let mediaStart = try XCTUnwrap(process.range(
            of: "mediaPipelineOwner.start("
        ))
        let recoveryInstall = try XCTUnwrap(process.range(
            of: "sleepWakeRecoveryOwner.install("
        ))
        let snapshotPolling = try XCTUnwrap(process.range(
            of: "pollingOwner.start()"
        ))
        let listener = try XCTUnwrap(process.range(
            of: "lifetime.activateXPCListener()"
        ))
        XCTAssertLessThan(mediaStart.lowerBound, recoveryInstall.lowerBound)
        XCTAssertLessThan(recoveryInstall.lowerBound, snapshotPolling.lowerBound)
        XCTAssertLessThan(snapshotPolling.lowerBound, listener.lowerBound)

        let recoveryCancel = try XCTUnwrap(process.range(
            of: "sleepWakeRecoveryOwner.cancelAndWait()"
        ))
        let mediaIngressCancel = try XCTUnwrap(process.range(
            of: "mediaState.cancelAndWait()"
        ))
        let mediaPipelineCancel = try XCTUnwrap(process.range(
            of: "mediaPipelineOwner.cancelAndWait()"
        ))
        let snapshotCancel = try XCTUnwrap(process.range(
            of: "pollingOwner.cancel()"
        ))
        XCTAssertLessThan(recoveryCancel.lowerBound, mediaIngressCancel.lowerBound)
        XCTAssertLessThan(mediaIngressCancel.lowerBound, mediaPipelineCancel.lowerBound)
        XCTAssertLessThan(mediaPipelineCancel.lowerBound, snapshotCancel.lowerBound)
        XCTAssertFalse(process.contains("NSWorkspace"))
    }

    func testProcessOwnerCancellationDrainsInstallationAndComposition() throws {
        let owner = try productSource(
            "HostAgentSleepWakeRecoveryProcessOwner.swift"
        )

        XCTAssertTrue(owner.contains("case installing"))
        XCTAssertTrue(owner.contains("case cancelling"))
        XCTAssertTrue(owner.contains("cancellationRequested = true"))
        XCTAssertTrue(owner.contains("while state == .installing"))
        XCTAssertTrue(owner.contains("while state == .cancelling"))
        XCTAssertTrue(owner.contains("composition?.cancel()"))
        let ingressCancel = try XCTUnwrap(owner.range(
            of: "notificationIngress?.cancelAndWait()"
        ))
        let compositionCancel = try XCTUnwrap(owner.range(
            of: "composition?.cancel()"
        ))
        XCTAssertLessThan(ingressCancel.lowerBound, compositionCancel.lowerBound)
        XCTAssertTrue(owner.contains("state = .cancelled"))
        XCTAssertTrue(owner.contains("condition.broadcast()"))
    }

    private func productSource(_ name: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/\(name)"
            ),
            encoding: .utf8
        )
    }
}
