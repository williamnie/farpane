@testable import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapPreparationTests: XCTestCase {
    func testPreparesPrivateAgentDirectoryBesideExistingCatalogIdempotently() throws {
        let fixture = try makeApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let product = fixture.applicationSupport.appendingPathComponent(
            HostAgentBootstrapProductLayout.productDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: product.path)
        let catalog = product.appendingPathComponent("catalog-v1.json")
        let sentinel = Data("existing-catalog-must-remain".utf8)
        try sentinel.write(to: catalog)

        let prepared = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: fixture.applicationSupport
        )

        XCTAssertEqual(
            prepared,
            HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: fixture.applicationSupport
            )
        )
        XCTAssertEqual(try Data(contentsOf: catalog), sentinel)
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: prepared.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o700
        )
        XCTAssertEqual(
            try HostAgentBootstrapProductDirectoryPreparer.prepare(
                applicationSupportURL: fixture.applicationSupport
            ),
            prepared
        )
    }

    func testRejectsProductAndAgentDirectorySymlinksWithoutFollowingThem() throws {
        let productSymlink = try makeApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: productSymlink.root) }
        let externalProduct = productSymlink.root.appendingPathComponent("ExternalProduct")
        try FileManager.default.createDirectory(at: externalProduct, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: productSymlink.applicationSupport.appendingPathComponent(
                HostAgentBootstrapProductLayout.productDirectoryName
            ),
            withDestinationURL: externalProduct
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapProductDirectoryPreparer.prepare(
                applicationSupportURL: productSymlink.applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapProductDirectoryPreparerError,
                .insecureProductDirectory
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalProduct.appendingPathComponent("HostAgent").path
            )
        )

        let agentSymlink = try makeApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: agentSymlink.root) }
        let product = agentSymlink.applicationSupport.appendingPathComponent(
            HostAgentBootstrapProductLayout.productDirectoryName
        )
        try FileManager.default.createDirectory(at: product, withIntermediateDirectories: false)
        let externalAgent = agentSymlink.root.appendingPathComponent("ExternalAgent")
        try FileManager.default.createDirectory(at: externalAgent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: product.appendingPathComponent(
                HostAgentBootstrapProductLayout.hostAgentDirectoryName
            ),
            withDestinationURL: externalAgent
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapProductDirectoryPreparer.prepare(
                applicationSupportURL: agentSymlink.applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapProductDirectoryPreparerError,
                .insecureHostAgentDirectory
            )
        }
    }

    func testRejectsExistingAgentDirectoryWithLoosePermissionsWithoutRepairingIt() throws {
        let fixture = try makeApplicationSupportFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let agent = HostAgentBootstrapProductLayout.directoryURL(
            applicationSupportURL: fixture.applicationSupport
        )
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agent.path)

        XCTAssertThrowsError(
            try HostAgentBootstrapProductDirectoryPreparer.prepare(
                applicationSupportURL: fixture.applicationSupport
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapProductDirectoryPreparerError,
                .insecureHostAgentDirectory
            )
        }
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: agent.path)[.posixPermissions]
                as? NSNumber)?.intValue,
            0o755
        )
    }

    func testBuildsDeterministicServerAndClipboardProjectionFromCanonicalCatalog() throws {
        let catalog = DeviceCatalogDocument(
            server: ServerConfiguration(
                displayName: "must-not-enter-agent-projection",
                rendezvousServer: "hermes.example.invalid:21116",
                serverPublicKey: "public-key",
                forceRelay: true
            ),
            devices: [
                SavedDevice(peerID: "peer-id-must-not-enter-agent-projection"),
            ]
        )

        let document = try HostAgentBootstrapProjectionBuilder.build(
            catalog: catalog,
            configRevision: 9,
            agentBuildID: "20260808155349"
        )
        let configuration = try HostAgentBootstrapConfiguration.decode(document)

        XCTAssertEqual(configuration.configRevision, 9)
        XCTAssertEqual(configuration.schemaVersion, 2)
        XCTAssertEqual(configuration.rendezvousServer, "hermes.example.invalid:21116")
        XCTAssertEqual(configuration.serverPublicKey, "public-key")
        XCTAssertEqual(configuration.clipboardPolicy, .disabled)
        XCTAssertEqual(
            document,
            try HostAgentBootstrapProjectionBuilder.build(
                catalog: catalog,
                configRevision: 9,
                agentBuildID: "20260808155349"
            )
        )
        let persisted = try XCTUnwrap(String(data: document, encoding: .utf8))
        for forbidden in [
            "must-not-enter-agent-projection",
            "peer-id-must-not-enter-agent-projection",
            "forceRelay",
            "devices",
            "displayName",
            "password",
            "token",
            "privateKey",
        ] {
            XCTAssertFalse(persisted.contains(forbidden))
        }
    }

    func testProjectionFailsClosedForMissingFutureOrUnsafeCatalogInput() throws {
        XCTAssertThrowsError(
            try HostAgentBootstrapProjectionBuilder.build(
                catalog: DeviceCatalogDocument(),
                configRevision: 1,
                agentBuildID: "build-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapProjectionBuilderError,
                .serverUnavailable
            )
        }
        XCTAssertThrowsError(
            try HostAgentBootstrapProjectionBuilder.build(
                catalog: DeviceCatalogDocument(schemaVersion: 2),
                configRevision: 1,
                agentBuildID: "build-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapProjectionBuilderError,
                .unsupportedCatalogSchema(2)
            )
        }

        let unsafe = DeviceCatalogDocument(
            server: ServerConfiguration(
                displayName: "unsafe",
                rendezvousServer: " hermes.example.invalid:21116",
                serverPublicKey: "public-key"
            )
        )
        for (revision, buildID) in [(1, "build-1"), (0, "build-1"), (1, "build\n1")] {
            let input = revision == 1 && buildID == "build-1" ? unsafe : DeviceCatalogDocument(
                server: ServerConfiguration(
                    displayName: "safe",
                    rendezvousServer: "hermes.example.invalid:21116",
                    serverPublicKey: "public-key"
                )
            )
            XCTAssertThrowsError(
                try HostAgentBootstrapProjectionBuilder.build(
                    catalog: input,
                    configRevision: UInt64(revision),
                    agentBuildID: buildID
                )
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentBootstrapProjectionBuilderError,
                    .invalidProjection
                )
            }
        }
    }

    private func makeApplicationSupportFixture() throws -> (
        root: URL,
        applicationSupport: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostAgentBootstrapPreparationTests-\(UUID().uuidString)")
        let applicationSupport = root.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: applicationSupport.path
        )
        return (root, applicationSupport)
    }
}
