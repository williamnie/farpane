@testable import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapLaunchPreflightTests: XCTestCase {
    func testLoadsFixedProjectionAndRequiresExactBuildIdentifier() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try publish(
            fixture: fixture,
            revision: 7,
            agentBuildID: "build-7",
            server: "one.example.invalid:21116"
        )
        let preflight = HostAgentBootstrapLaunchPreflight(
            applicationSupportURL: fixture.applicationSupport
        )

        let configuration = try preflight.prepare(
            expectedAgentBuildID: "build-7"
        )
        XCTAssertEqual(configuration.configRevision, 7)
        XCTAssertEqual(configuration.agentBuildID, "build-7")
        XCTAssertEqual(configuration.rendezvousServer, "one.example.invalid:21116")
        XCTAssertEqual(configuration.hostConfigAppName, "FarPaneHost")
        XCTAssertEqual(configuration.hostConfigOrganization, "io.rustdesknative")

        let originalBytes = try Data(contentsOf: fixture.projectionURL)
        XCTAssertThrowsError(
            try preflight.prepare(expectedAgentBuildID: "build-8")
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapLaunchPreflightError,
                .buildIdentifierMismatch
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.projectionURL), originalBytes)
    }

    func testRejectsInvalidExpectedBuildIdentifierBeforeFilesystemAccess() {
        let missingApplicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HostAgentBootstrapLaunchPreflightMissing-\(UUID().uuidString)",
                isDirectory: true
            )
        let preflight = HostAgentBootstrapLaunchPreflight(
            applicationSupportURL: missingApplicationSupport
        )

        for value in ["", " build-7", "build/7", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(
                try preflight.prepare(expectedAgentBuildID: value)
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentBootstrapLaunchPreflightError,
                    .buildIdentifierUnavailable
                )
            }
        }
    }

    func testCorruptProjectionPropagatesStrictDecoderErrorAndPreservesBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try publish(
            fixture: fixture,
            revision: 1,
            agentBuildID: "build-1",
            server: "one.example.invalid:21116"
        )
        let corruptBytes = Data("{}".utf8)
        try corruptBytes.write(to: fixture.projectionURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fixture.projectionURL.path
        )

        XCTAssertThrowsError(
            try HostAgentBootstrapLaunchPreflight(
                applicationSupportURL: fixture.applicationSupport
            ).prepare(expectedAgentBuildID: "build-1")
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.projectionURL), corruptBytes)
    }

    private func publish(
        fixture: Fixture,
        revision: UInt64,
        agentBuildID: String,
        server: String
    ) throws {
        let directory = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: fixture.applicationSupport
        )
        let document = try HostAgentBootstrapProjectionBuilder.build(
            catalog: DeviceCatalogDocument(
                server: ServerConfiguration(
                    displayName: "test",
                    rendezvousServer: server,
                    serverPublicKey: "public-key"
                )
            ),
            configRevision: revision,
            agentBuildID: agentBuildID
        )
        _ = try HostAgentBootstrapConfigurationPublisher(
            directoryURL: directory
        ).publish(document)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostAgentBootstrapLaunchPreflightTests-\(UUID().uuidString)",
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
        let projectionURL = HostAgentBootstrapProductLayout.directoryURL(
            applicationSupportURL: applicationSupport
        ).appendingPathComponent(
            HostAgentBootstrapConfigurationReader.configurationFileName
        )
        return Fixture(
            root: root,
            applicationSupport: applicationSupport,
            projectionURL: projectionURL
        )
    }
}

private struct Fixture {
    let root: URL
    let applicationSupport: URL
    let projectionURL: URL
}
