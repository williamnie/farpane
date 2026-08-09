import Foundation
import XCTest

final class HostAgentSleepWakeRecoveryCompositionContractTests: XCTestCase {
    func testCompositionHardBindsMediaAndRegistrationRecoveryOwners() throws {
        let source = try productSource(
            "HostAgentSleepWakeRecoveryComposition.swift"
        )

        XCTAssertTrue(source.contains(
            "HostAgentSleepWakeRecoveryOwner("
        ))
        XCTAssertTrue(source.contains(
            "mediaPipelineOwner.pauseMediaAndFlushForSleep()"
        ))
        XCTAssertTrue(source.contains(
            "mediaPipelineOwner.beginMediaRecoveryAfterWake("
        ))
        XCTAssertTrue(source.contains(
            "epoch: epoch,\n                        completion: completion"
        ))
        XCTAssertFalse(source.contains("let pauseMediaAndFlush:"))
        XCTAssertFalse(source.contains("let beginMediaRecovery:"))
        XCTAssertFalse(source.contains("pauseMediaAndFlush: operations."))
        XCTAssertFalse(source.contains("beginMediaRecovery: operations."))
        XCTAssertTrue(source.contains(
            "registrationRecoveryOwner.start("
        ))
        XCTAssertTrue(source.contains(
            "beginRegistrationRecovery: { epoch, completion in"
        ))
        XCTAssertTrue(source.contains(
            "epoch: epoch,\n                        completion: completion"
        ))
        XCTAssertFalse(source.contains("resumeRegistration"))
        XCTAssertFalse(source.contains("let beginRegistrationRecovery:"))
        XCTAssertFalse(source.contains(
            "beginRegistrationRecovery: operations."
        ))
    }

    func testCompositionRequiresRemainingProductOperationsAndForwardsLifecycle() throws {
        let source = try productSource(
            "HostAgentSleepWakeRecoveryComposition.swift"
        )

        for operation in [
            "withdrawAvailability",
            "publishSuspending",
            "releaseSleepAssertion",
            "publishAvailable",
        ] {
            XCTAssertTrue(source.contains("let \(operation): @Sendable"))
            XCTAssertTrue(source.contains(
                "\(operation): operations.\(operation)"
            ))
        }
        XCTAssertTrue(source.contains("owner.snapshot()"))
        XCTAssertTrue(source.contains("owner.systemWillSleep()"))
        XCTAssertTrue(source.contains("owner.systemDidWake()"))
        XCTAssertTrue(source.contains("deinit {\n        cancel()"))
        XCTAssertTrue(source.contains("owner.cancel()"))
        XCTAssertTrue(source.contains(
            "registrationRecoveryOwner.cancelAndWait()"
        ))
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
