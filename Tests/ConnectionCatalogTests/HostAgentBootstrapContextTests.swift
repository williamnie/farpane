@testable import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapContextTests: XCTestCase {
    func testBindsValidatedConfigurationBootIDAndLiveLease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try publish(fixture: fixture, revision: 7, buildID: "build-7")
        let bootID = UUID()
        let context = try HostAgentBootstrapContext.prepare(
            applicationSupportURL: fixture.applicationSupport,
            expectedAgentBuildID: "build-7",
            agentBootID: bootID
        )

        XCTAssertEqual(context.agentBootID, bootID)
        XCTAssertEqual(context.configuration.configRevision, 7)
        XCTAssertEqual(context.configuration.agentBuildID, "build-7")
        XCTAssertEqual(
            context.leaseRecord,
            HostAgentSingleWriterLeaseRecord(
                agentBootID: bootID,
                agentBuildID: "build-7",
                configRevision: 7
            )
        )
        let liveBytes = try Data(contentsOf: fixture.leaseURL)
        XCTAssertThrowsError(
            try HostAgentBootstrapContext.prepare(
                applicationSupportURL: fixture.applicationSupport,
                expectedAgentBuildID: "build-7",
                agentBootID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentSingleWriterLeaseError,
                .alreadyHeld
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.leaseURL), liveBytes)
        withExtendedLifetime(context) {}
    }

    func testPreflightFailureCannotReplaceStaleLeaseRecord() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try publish(fixture: fixture, revision: 1, buildID: "build-1")
        let validConfiguration = try HostAgentBootstrapLaunchPreflight(
            applicationSupportURL: fixture.applicationSupport
        ).prepare(expectedAgentBuildID: "build-1")
        let stale = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: validConfiguration,
            agentBootID: UUID()
        )
        stale.release()
        let staleRecordBytes = try Data(contentsOf: fixture.leaseURL)
        let corruptBytes = Data("{}".utf8)
        try corruptBytes.write(to: fixture.projectionURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.projectionURL.path
        )

        XCTAssertThrowsError(
            try HostAgentBootstrapContext.prepare(
                applicationSupportURL: fixture.applicationSupport,
                expectedAgentBuildID: "build-1",
                agentBootID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.leaseURL), staleRecordBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.projectionURL), corruptBytes)
    }

    func testContextDeinitReleasesLeaseForNextBoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try publish(fixture: fixture, revision: 3, buildID: "build-3")
        let firstBootID = UUID()
        do {
            let first = try HostAgentBootstrapContext.prepare(
                applicationSupportURL: fixture.applicationSupport,
                expectedAgentBuildID: "build-3",
                agentBootID: firstBootID
            )
            XCTAssertEqual(first.agentBootID, firstBootID)
            withExtendedLifetime(first) {}
        }

        let nextBootID = UUID()
        let next = try HostAgentBootstrapContext.prepare(
            applicationSupportURL: fixture.applicationSupport,
            expectedAgentBuildID: "build-3",
            agentBootID: nextBootID
        )
        XCTAssertEqual(next.agentBootID, nextBootID)
        XCTAssertEqual(next.leaseRecord.agentBootID, nextBootID)
        withExtendedLifetime(next) {}
    }

    private func publish(
        fixture: Fixture,
        revision: UInt64,
        buildID: String
    ) throws {
        let document = try HostAgentBootstrapProjectionBuilder.build(
            catalog: DeviceCatalogDocument(
                server: ServerConfiguration(
                    displayName: "test",
                    rendezvousServer: "one.example.invalid:21116",
                    serverPublicKey: "public-key"
                )
            ),
            configRevision: revision,
            agentBuildID: buildID
        )
        _ = try HostAgentBootstrapConfigurationPublisher(
            directoryURL: fixture.directory
        ).publish(document)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostAgentBootstrapContextTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let applicationSupport = root.appendingPathComponent(
            "Application Support",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: applicationSupport.path
        )
        let directory = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: applicationSupport
        )
        return Fixture(
            root: root,
            applicationSupport: applicationSupport,
            directory: directory,
            projectionURL: directory.appendingPathComponent(
                HostAgentBootstrapConfigurationReader.configurationFileName
            ),
            leaseURL: directory.appendingPathComponent(
                HostAgentSingleWriterLease.leaseFileName
            )
        )
    }
}

private struct Fixture {
    let root: URL
    let applicationSupport: URL
    let directory: URL
    let projectionURL: URL
    let leaseURL: URL
}
