@testable import ConnectionCatalog
import Darwin
import Foundation
import XCTest

final class HostAgentBootstrapProductIntegrationTests: XCTestCase {
    func testReconcilesOnlyTheCanonicalSavedCatalog() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let integration = try HostAgentBootstrapProductIntegration(
            applicationSupportURL: fixture.applicationSupport,
            agentBuildID: "202608080001"
        )

        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .waitingForServer
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.projectionURL.path))

        try fixture.store.save(catalog(server: "one.example.invalid:21116"))
        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .ready(configRevision: 1)
        )

        var unsaved = try fixture.store.load()
        unsaved.server = server("unsaved.example.invalid:21116")
        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .ready(configRevision: 1)
        )
        XCTAssertEqual(
            try readProjection(fixture).rendezvousServer,
            "one.example.invalid:21116"
        )

        try fixture.store.save(unsaved)
        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .ready(configRevision: 2)
        )
        XCTAssertEqual(
            try readProjection(fixture).rendezvousServer,
            "unsaved.example.invalid:21116"
        )
    }

    func testBuildIdentifierRequiresExactValidBundleVersion() throws {
        XCTAssertEqual(
            try HostAgentBootstrapProductIntegration.agentBuildID(
                from: ["CFBundleVersion": "202608080001"]
            ),
            "202608080001"
        )

        for infoDictionary: [String: Any]? in [
            nil,
            ["CFBundleShortVersionString": "0.1.0"],
            ["CFBundleVersion": NSNumber(value: 42)],
            ["CFBundleVersion": " 42"],
            ["CFBundleVersion": "build/42"],
        ] {
            XCTAssertThrowsError(
                try HostAgentBootstrapProductIntegration.agentBuildID(
                    from: infoDictionary
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentBootstrapProductIntegrationError,
                    .buildIdentifierUnavailable
                )
            }
        }
    }

    func testReconcilesExplicitClipboardPolicyIntoCanonicalProjection() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let integration = try HostAgentBootstrapProductIntegration(
            applicationSupportURL: fixture.applicationSupport,
            agentBuildID: "202608080001"
        )
        try fixture.store.save(catalog(server: "one.example.invalid:21116"))

        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: HostAgentClipboardPolicy(
                    allowRemoteRead: false,
                    allowRemoteWrite: true,
                    allowRemoteRichTextRead: true,
                    allowRemoteRichTextWrite: false,
                    allowRemoteImageRead: true,
                    allowRemoteImageWrite: false
                )
            ),
            .ready(configRevision: 1)
        )
        let configuration = try readProjection(fixture)
        XCTAssertEqual(configuration.schemaVersion, 5)
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        XCTAssertEqual(
            configuration.clipboardPolicy,
            HostAgentClipboardPolicy(
                allowRemoteRead: false,
                allowRemoteWrite: true,
                allowRemoteRichTextRead: true,
                allowRemoteRichTextWrite: false,
                allowRemoteImageRead: true,
                allowRemoteImageWrite: false
            )
        )
    }

    func testPublicationBusyDegradesWithoutRollingBackCatalogAndCanRetry() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let integration = try HostAgentBootstrapProductIntegration(
            applicationSupportURL: fixture.applicationSupport,
            agentBuildID: "202608080001"
        )
        try fixture.store.save(catalog(server: "one.example.invalid:21116"))
        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .ready(configRevision: 1)
        )
        try fixture.store.save(catalog(server: "two.example.invalid:21116"))

        let lockURL = fixture.projectionURL.deletingLastPathComponent()
            .appendingPathComponent(
                HostAgentBootstrapConfigurationPublisher.publicationLockFileName
            )
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .degraded
        )
        XCTAssertEqual(
            try fixture.store.load().server?.rendezvousServer,
            "two.example.invalid:21116"
        )
        XCTAssertEqual(try readProjection(fixture).configRevision, 1)
        XCTAssertEqual(
            try readProjection(fixture).rendezvousServer,
            "one.example.invalid:21116"
        )

        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(
            integration.reconcileSavedCatalog(
                from: fixture.store,
                clipboardPolicy: .disabled
            ),
            .ready(configRevision: 2)
        )
        XCTAssertEqual(
            try readProjection(fixture).rendezvousServer,
            "two.example.invalid:21116"
        )
    }

    private func catalog(server rendezvousServer: String) -> DeviceCatalogDocument {
        DeviceCatalogDocument(server: server(rendezvousServer))
    }

    private func server(_ rendezvousServer: String) -> ServerConfiguration {
        ServerConfiguration(
            displayName: "test",
            rendezvousServer: rendezvousServer,
            serverPublicKey: "public-key"
        )
    }

    private func readProjection(_ fixture: Fixture) throws
        -> HostAgentBootstrapConfiguration
    {
        try HostAgentBootstrapConfigurationReader(
            directoryURL: fixture.projectionURL.deletingLastPathComponent()
        ).load()
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostAgentBootstrapProductIntegrationTests-\(UUID().uuidString)",
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
        let store = DeviceCatalogStore(
            fileURL: applicationSupport
                .appendingPathComponent("RustDesk Native Viewer", isDirectory: true)
                .appendingPathComponent("catalog-v1.json")
        )
        let projectionURL = HostAgentBootstrapProductLayout.directoryURL(
            applicationSupportURL: applicationSupport
        ).appendingPathComponent(
            HostAgentBootstrapConfigurationReader.configurationFileName
        )
        return Fixture(
            root: root,
            applicationSupport: applicationSupport,
            store: store,
            projectionURL: projectionURL
        )
    }
}

private struct Fixture {
    let root: URL
    let applicationSupport: URL
    let store: DeviceCatalogStore
    let projectionURL: URL
}
