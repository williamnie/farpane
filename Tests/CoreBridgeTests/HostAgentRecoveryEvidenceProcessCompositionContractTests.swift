import Foundation
import XCTest

final class HostAgentRecoveryEvidenceProcessCompositionContractTests:
    XCTestCase
{
    func testProcessOwnsOneBestEffortEvidenceLifetime() throws {
        let process = try repositorySource(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )

        XCTAssertEqual(
            process.components(
                separatedBy: "HostRecoveryTransitionEvidenceProcessOwner()"
            ).count - 1,
            1
        )
        XCTAssertTrue(process.contains(
            "_ = recoveryEvidenceOwner.configure(\n"
                + "                    hostInstanceID: hostInstanceID,\n"
                + "                    buildIdentity: expectedAgentBuildID"
        ))
        XCTAssertFalse(process.contains(
            "guard recoveryEvidenceOwner.configure("
        ))
        XCTAssertFalse(process.contains(
            "try recoveryEvidenceOwner.configure("
        ))

        try assertOrder(
            in: process,
            "guard let hostInstanceID = snapshotState.snapshot().hostInstanceID",
            "_ = recoveryEvidenceOwner.configure("
        )
        try assertOrder(
            in: process,
            "_ = recoveryEvidenceOwner.configure(",
            "mediaPipelineOwner.start("
        )
    }

    func testRecoveryOwnersDrainBeforeEvidenceAndMediaTeardown() throws {
        let process = try repositorySource(
            "Sources/RustDeskNative/HostAgentProcess.swift"
        )

        try assertOrder(
            in: process,
            "networkPathRecoveryOwner.cancelAndWait()",
            "sleepWakeRecoveryOwner.cancelAndWait()"
        )
        try assertOrder(
            in: process,
            "sleepWakeRecoveryOwner.cancelAndWait()",
            "recoveryEvidenceOwner.cancelAndWait()"
        )
        try assertOrder(
            in: process,
            "recoveryEvidenceOwner.cancelAndWait()",
            "mediaState.cancelAndWait()"
        )
        try assertOrder(
            in: process,
            "recoveryEvidenceOwner.cancelAndWait()",
            "mediaPipelineOwner.cancelAndWait()"
        )
    }

    func testDigestAuthorityAndOutputConfigurationRemainSeparated() throws {
        let owner = try repositorySource(
            "Sources/VideoPipeline/HostRecoveryTransitionEvidenceProcessOwner.swift"
        )
        let writer = try repositorySource(
            "Sources/VideoPipeline/HostRecoveryTransitionEvidence.swift"
        )

        XCTAssertTrue(owner.contains("import CryptoKit"))
        XCTAssertTrue(owner.contains(
            "farpane.host-recovery.scope.v1"
        ))
        XCTAssertTrue(owner.contains(
            "farpane.host-recovery.build.v1"
        ))
        XCTAssertTrue(owner.contains("hasher.update(data: Data([0]))"))
        XCTAssertTrue(owner.contains("maximumIdentityUTF8Bytes = 512"))
        XCTAssertTrue(owner.contains(
            "HostRecoveryTransitionEvidenceWriter.configured("
        ))
        XCTAssertTrue(writer.contains(
            "public static let outputEnvironmentKey = "
                + "\"FARPANE_HOST_RECOVERY_OUTPUT\""
        ))
        XCTAssertFalse(writer.contains(
            "FARPANE_HOST_RECOVERY_SCOPE_SHA256"
        ))
        XCTAssertFalse(writer.contains(
            "FARPANE_HOST_RECOVERY_BUILD_SHA256"
        ))
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
