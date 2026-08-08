import Foundation
import XCTest

final class HostAgentXPCProcessIdentityIntegrationTests: XCTestCase {
    func testRuntimeUsesExactLeaseBoundBootstrapIdentity() throws {
        let source = try productSource("HostAgentProcessRuntime.swift")

        try assertOrder(
            in: source,
            "let bootstrapContext = try HostAgentBootstrapContext.prepare()",
            "HostAgentXPCProcessIdentityAuthority.makeProduct("
        )
        try assertOrder(
            in: source,
            "HostAgentXPCProcessIdentityAuthority.makeProduct(",
            "let ownedRuntime = try HostAgentOwnedCoreRuntime.start("
        )
        XCTAssertTrue(source.contains(
            "agentBuildID: bootstrapContext.leaseRecord.agentBuildID"
        ))
        XCTAssertTrue(source.contains(
            "bootstrapContext.leaseRecord.agentBootID.uuidString.lowercased()"
        ))
        XCTAssertFalse(source.contains("UUID()"))
        XCTAssertFalse(source.contains("Bundle.main"))
        XCTAssertFalse(source.contains("ProcessInfo"))
        XCTAssertFalse(source.contains("getenv"))
    }

    func testInitialSnapshotBindsIdentityBeforeMediaPollingAndListener() throws {
        let source = try productSource("HostAgentProcess.swift")

        try assertOrder(
            in: source,
            "let hostInstanceID = snapshotState.snapshot().hostInstanceID",
            "lifetime.bindXPCIdentity("
        )
        try assertOrder(
            in: source,
            "lifetime.bindXPCIdentity(",
            "mediaPipelineOwner.start("
        )
        try assertOrder(
            in: source,
            "lifetime.bindXPCIdentity(",
            "pollingOwner.start()"
        )
        try assertOrder(
            in: source,
            "mediaPipelineOwner.start(",
            "lifetime.activateXPCListener()"
        )
        try assertOrder(
            in: source,
            "pollingOwner.start()",
            "lifetime.activateXPCListener()"
        )
    }

    func testTerminationInvalidatesIdentityBeforeOtherPreparationAndStop() throws {
        let lifetimeSource = try productSource("HostAgentProcessLifetime.swift")
        let runtimeSource = try productSource("HostAgentProcessRuntime.swift")

        try assertOrder(
            in: lifetimeSource,
            "runtime.invalidateXPCIdentity()",
            "prepareTermination()"
        )
        try assertOrder(
            in: runtimeSource,
            "xpcIdentityAuthority.invalidate()",
            "try ownedRuntime.stop(reason: reason)"
        )
    }

    func testSnapshotAuthorityFailureInvalidatesThroughRunningLifetimeGate() throws {
        let processSource = try productSource("HostAgentProcess.swift")
        let lifetimeSource = try productSource("HostAgentProcessLifetime.swift")

        XCTAssertTrue(processSource.contains(
            "onIdentityInvalidationRequired: { [weak lifetime] _ in"
        ))
        try assertOrder(
            in: processSource,
            "onIdentityInvalidationRequired:",
            "try? lifetime.invalidateXPCIdentity()"
        )
        XCTAssertTrue(lifetimeSource.contains(
            """
            func invalidateXPCIdentity() throws {
                    try gate.withRunningRuntime { runtime in
                        runtime.invalidateXPCIdentity()
                    }
                }
            """
        ))
    }

    func testRuntimeOwnsAdmissionOwnerFromSameAuthorityAndEntryRemainsDisabled() throws {
        let runtimeSource = try productSource("HostAgentProcessRuntime.swift")
        let lifetimeSource = try productSource("HostAgentProcessLifetime.swift")
        let appSource = try productSource("RustDeskNativeApp.swift")

        try assertOrder(
            in: runtimeSource,
            "HostAgentXPCProcessIdentityAuthority.makeProduct(",
            "HostAgentXPCListenerAdmissionShell.makeProductShell("
        )
        XCTAssertTrue(runtimeSource.contains(
            "identityAuthority: xpcIdentityAuthority"
        ))
        XCTAssertTrue(runtimeSource.contains(
            "snapshotState: snapshotState"
        ))
        XCTAssertTrue(runtimeSource.contains("xpcAdmissionOwner"))
        XCTAssertTrue(lifetimeSource.contains(
            "func activateXPCListener() throws"
        ))
        XCTAssertFalse(appSource.contains("HostAgentProcess.run("))
        XCTAssertTrue(appSource.contains("HostAgentBootstrap.failClosed()"))
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
