import Foundation
import XCTest

final class HostAgentNetworkPathRecoveryCompositionContractTests: XCTestCase {
    func testNetworkABIIsForwardedThroughTheSameRuntimeLifetimeChain() throws {
        let coreRuntime = try repositorySource(
            "Sources/CoreBridge/HostAgentCoreRuntime.swift"
        )
        let ownedRuntime = try repositorySource(
            "Sources/CoreBridge/HostAgentOwnedCoreRuntime.swift"
        )
        let processRuntime = try productSource(
            "HostAgentProcessRuntime.swift"
        )
        let lifetime = try productSource(
            "HostAgentProcessLifetime.swift"
        )

        XCTAssertTrue(coreRuntime.contains(
            "func recoverNetworkPath(generation: UInt64) throws"
        ))
        XCTAssertTrue(coreRuntime.contains(
            "client.recoverNetworkPath(generation: generation)"
        ))
        XCTAssertTrue(ownedRuntime.contains(
            "runtime.recoverNetworkPath(generation: generation)"
        ))
        XCTAssertTrue(processRuntime.contains(
            "ownedRuntime.recoverNetworkPath(generation: generation)"
        ))
        XCTAssertTrue(lifetime.contains(
            "runtime.recoverNetworkPath(generation: generation)"
        ))
        XCTAssertTrue(lifetime.contains("gate.withRunningRuntime"))
    }

    func testCompositionHardBindsTriggerPollingAndAuthoritativeLifetime() throws {
        let source = try productSource(
            "HostAgentNetworkPathRecoveryComposition.swift"
        )

        XCTAssertTrue(source.contains(
            "HostAgentNetworkPathRecoveryPollingOwner.makeProduct("
        ))
        XCTAssertTrue(source.contains(
            "expectedHostInstanceID: expectedHostInstanceID"
        ))
        XCTAssertTrue(source.contains(
            "lifetime.recoverNetworkPath("
        ))
        XCTAssertTrue(source.contains(
            "generation: pathGeneration"
        ))
        XCTAssertTrue(source.contains(
            "return .snapshot(try lifetime.copySnapshot())"
        ))
        XCTAssertTrue(source.contains(
            "catch HostAgentProcessLifetimeAccessError.notRunning"
        ))
        XCTAssertTrue(source.contains("return .failed"))
        XCTAssertTrue(source.contains("return .unavailable"))
        XCTAssertTrue(source.contains(
            "HostAgentNetworkPathRecoveryTriggerOwner {"
        ))
        XCTAssertTrue(source.contains(
            "pollingOwner.start("
        ))
        XCTAssertTrue(source.contains(
            "pathGeneration: pathGeneration"
        ))
        XCTAssertTrue(source.contains(
            "snapshotCoordinator.requestPoll()"
        ))
        XCTAssertTrue(source.contains(
            "recoveryEvidenceOwner.acceptNetworkPath("
        ))
        XCTAssertTrue(source.contains(
            "recoveryEvidenceOwner.recordNetworkPathCompleted("
        ))
        XCTAssertFalse(source.contains("let recover: @Sendable"))
        XCTAssertFalse(source.contains("let observe: @Sendable"))
    }

    func testCompositionFailureIsAsynchronousAndTeardownDrainsInOrder() throws {
        let source = try productSource(
            "HostAgentNetworkPathRecoveryComposition.swift"
        )
        let polling = try repositorySource(
            "Sources/CoreBridge/HostAgentNetworkPathRecoveryPollingOwner.swift"
        )

        try assertOrder(
            in: source,
            "DispatchQueue.global(qos: .utility).async",
            "lifetime?.requestTermination(reason: .error)"
        )
        XCTAssertTrue(source.contains(
            "guard succeeded else {\n                        requestTermination()"
        ))
        try assertOrder(
            in: source,
            "triggerOwner.cancelAndWait()",
            "pollingOwner.cancelAndWait()"
        )
        XCTAssertTrue(source.contains("deinit {\n        cancelAndWait()"))
        XCTAssertTrue(polling.contains(
            "recoveryAccepted(pathGeneration, recoveryEpoch)"
        ))
        XCTAssertTrue(polling.contains(
            "let shouldRecordCompleted: Bool"
        ))
        XCTAssertTrue(polling.contains(
            "shouldRecordCompleted = outcome == .converged"
        ))
        XCTAssertTrue(polling.contains(
            "if shouldRecordCompleted {\n"
                + "            recoveryCompleted(pathGeneration, recoveryEpoch)"
        ))
        try assertOrder(
            in: polling,
            "recoveryCompleted(pathGeneration, recoveryEpoch)",
            "condition.lock()\n        completionInFlight = false"
        )
    }

    func testProcessOwnsCompositionInsideTheExistingStartupLifetime() throws {
        let process = try productSource("HostAgentProcess.swift")
        let owner = try productSource(
            "HostAgentNetworkPathRecoveryProcessOwner.swift"
        )

        XCTAssertTrue(process.contains(
            "HostAgentNetworkPathRecoveryProcessOwner()"
        ))
        XCTAssertTrue(process.contains(
            "recoveryEvidenceOwner: recoveryEvidenceOwner"
        ))
        let sleepInstall = try XCTUnwrap(process.range(
            of: "sleepWakeRecoveryOwner.install("
        ))
        let networkInstall = try XCTUnwrap(process.range(
            of: "networkPathRecoveryOwner.install("
        ))
        let snapshotPolling = try XCTUnwrap(process.range(
            of: "pollingOwner.start()"
        ))
        let listener = try XCTUnwrap(process.range(
            of: "lifetime.activateXPCListener()"
        ))
        XCTAssertLessThan(sleepInstall.lowerBound, networkInstall.lowerBound)
        XCTAssertLessThan(networkInstall.lowerBound, snapshotPolling.lowerBound)
        XCTAssertLessThan(networkInstall.lowerBound, listener.lowerBound)

        let networkCancel = try XCTUnwrap(process.range(
            of: "networkPathRecoveryOwner.cancelAndWait()"
        ))
        let sleepCancel = try XCTUnwrap(process.range(
            of: "sleepWakeRecoveryOwner.cancelAndWait()"
        ))
        XCTAssertLessThan(networkCancel.lowerBound, sleepCancel.lowerBound)

        XCTAssertTrue(owner.contains("case installing"))
        XCTAssertTrue(owner.contains("case cancelling"))
        XCTAssertTrue(owner.contains("cancellationRequested = true"))
        XCTAssertTrue(owner.contains("while state == .installing"))
        XCTAssertTrue(owner.contains("while state == .cancelling"))
        XCTAssertTrue(owner.contains(
            "HostAgentNWPathMonitorIngress.makeProduct("
        ))
        XCTAssertTrue(owner.contains(
            "recoveryEvidenceOwner: HostRecoveryTransitionEvidenceProcessOwner"
        ))
        XCTAssertTrue(owner.contains("guard pathIngress.start()"))
        let ingressCancel = try XCTUnwrap(owner.range(
            of: "pathIngress?.cancelAndWait()"
        ))
        let compositionCancel = try XCTUnwrap(owner.range(
            of: "composition?.cancelAndWait()"
        ))
        XCTAssertLessThan(
            ingressCancel.lowerBound,
            compositionCancel.lowerBound
        )
        XCTAssertTrue(owner.contains("composition?.cancelAndWait()"))
        XCTAssertTrue(owner.contains("guard state == .installed"))
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

    private func assertOrder(
        in source: String,
        _ earlier: String,
        _ later: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let earlierRange = try XCTUnwrap(
            source.range(of: earlier),
            "missing earlier source marker",
            file: file,
            line: line
        )
        let laterRange = try XCTUnwrap(
            source.range(of: later),
            "missing later source marker",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            earlierRange.lowerBound,
            laterRange.lowerBound,
            file: file,
            line: line
        )
    }
}
