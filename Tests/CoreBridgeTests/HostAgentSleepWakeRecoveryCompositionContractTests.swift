import Foundation
import XCTest

final class HostAgentSleepWakeRecoveryCompositionContractTests: XCTestCase {
    func testCompositionHardBindsMediaAndExactEpochCoreRecovery() throws {
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
            "HostAgentRegistrationRecoveryPollingOwner.makeProduct("
        ))
        XCTAssertTrue(source.contains(
            "expectedHostInstanceID: expectedHostInstanceID"
        ))
        XCTAssertTrue(source.contains("lifetime.beginSleep(epoch: epoch)"))
        XCTAssertTrue(source.contains("lifetime.finishSleep(epoch: epoch)"))
        XCTAssertTrue(source.contains("lifetime.resumeAfterWake(epoch: epoch)"))
        XCTAssertTrue(source.contains("lifetime.copySnapshot()"))
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
        XCTAssertFalse(source.contains("let withdrawAvailability: @Sendable"))
        XCTAssertFalse(source.contains("let releaseSleepAssertion: @Sendable"))
    }

    func testCompositionRequiresOnlyProjectionOperationsAndForwardsLifecycle() throws {
        let source = try productSource(
            "HostAgentSleepWakeRecoveryComposition.swift"
        )

        for operation in [
            "publishSuspending",
            "publishAvailable",
        ] {
            XCTAssertTrue(source.contains("let \(operation): @Sendable"))
            XCTAssertTrue(source.contains(
                "operations.\(operation)(epoch)"
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

    func testSleepABIIsForwardedThroughTheSameRuntimeLifetimeChain() throws {
        let coreRuntime = try repositorySource(
            "Sources/CoreBridge/HostAgentCoreRuntime.swift"
        )
        let ownedRuntime = try repositorySource(
            "Sources/CoreBridge/HostAgentOwnedCoreRuntime.swift"
        )
        let processRuntime = try repositorySource(
            "Sources/RustDeskNative/HostAgentProcessRuntime.swift"
        )
        let lifetime = try repositorySource(
            "Sources/RustDeskNative/HostAgentProcessLifetime.swift"
        )

        for operation in ["beginSleep", "finishSleep", "resumeAfterWake"] {
            XCTAssertTrue(coreRuntime.contains(
                "func \(operation)(epoch: UInt64) throws"
            ))
            XCTAssertTrue(coreRuntime.contains(
                "client.\(operation)(epoch: epoch)"
            ))
            XCTAssertTrue(ownedRuntime.contains(
                "runtime.\(operation)(epoch: epoch)"
            ))
            XCTAssertTrue(processRuntime.contains(
                "ownedRuntime.\(operation)(epoch: epoch)"
            ))
            XCTAssertTrue(lifetime.contains(
                "runtime.\(operation)(epoch: epoch)"
            ))
        }
        XCTAssertTrue(lifetime.contains("gate.withRunningRuntime"))
    }

    private func productSource(_ name: String) throws -> String {
        try repositorySource("Sources/RustDeskNative/\(name)")
    }

    private func repositorySource(_ path: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
