@testable import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentBootstrapConfigurationReaderTests: XCTestCase {
    func testLoadsOnlyTheFixedPrivateRegularConfigurationFile() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeValidDocument(to: fixture.configuration)

        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: fixture.directory
        ).load()

        XCTAssertEqual(configuration.configRevision, 7)
        XCTAssertEqual(configuration.rendezvousServer, "hermes.example.invalid:21116")
        XCTAssertEqual(
            HostAgentBootstrapConfigurationReader.configurationFileName,
            "bootstrap-v1.json"
        )
    }

    func testRejectsMissingSymlinkAndNonRegularConfigurationFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reader = HostAgentBootstrapConfigurationReader(directoryURL: fixture.directory)

        XCTAssertThrowsError(try reader.load()) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .configurationUnavailable
            )
        }

        let external = fixture.root.appendingPathComponent("external.json")
        try writeValidDocument(to: external)
        try FileManager.default.createSymbolicLink(
            at: fixture.configuration,
            withDestinationURL: external
        )
        XCTAssertThrowsError(try reader.load()) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .insecureConfigurationFile
            )
        }

        try FileManager.default.removeItem(at: fixture.configuration)
        try FileManager.default.createDirectory(at: fixture.configuration, withIntermediateDirectories: false)
        XCTAssertThrowsError(try reader.load()) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .insecureConfigurationFile
            )
        }
    }

    func testRejectsLoosePermissionsHardLinksAndInsecureDirectory() throws {
        let looseFile = try makeFixture()
        defer { try? FileManager.default.removeItem(at: looseFile.root) }
        try writeValidDocument(to: looseFile.configuration)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: looseFile.configuration.path
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapConfigurationReader(directoryURL: looseFile.directory).load()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .insecureConfigurationFile
            )
        }

        let hardLink = try makeFixture()
        defer { try? FileManager.default.removeItem(at: hardLink.root) }
        try writeValidDocument(to: hardLink.configuration)
        try FileManager.default.linkItem(
            at: hardLink.configuration,
            to: hardLink.root.appendingPathComponent("alias.json")
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapConfigurationReader(directoryURL: hardLink.directory).load()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .insecureConfigurationFile
            )
        }

        let looseDirectory = try makeFixture()
        defer { try? FileManager.default.removeItem(at: looseDirectory.root) }
        try writeValidDocument(to: looseDirectory.configuration)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: looseDirectory.directory.path
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapConfigurationReader(directoryURL: looseDirectory.directory).load()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .insecureDirectory
            )
        }

        let symlinkDirectory = try makeFixture()
        defer { try? FileManager.default.removeItem(at: symlinkDirectory.root) }
        try writeValidDocument(to: symlinkDirectory.configuration)
        let symlink = symlinkDirectory.root.appendingPathComponent("HostAgentAlias")
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: symlinkDirectory.directory
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapConfigurationReader(directoryURL: symlink).load()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationReaderError,
                .insecureDirectory
            )
        }
    }

    private func makeFixture() throws -> (
        root: URL,
        directory: URL,
        configuration: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostAgentBootstrapReaderTests-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("HostAgent", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return (
            root,
            directory,
            directory.appendingPathComponent(
                HostAgentBootstrapConfigurationReader.configurationFileName,
                isDirectory: false
            )
        )
    }

    private func writeValidDocument(to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "configRevision": 7,
            "agentBuildID": "20260808155349",
            "server": [
                "rendezvousServer": "hermes.example.invalid:21116",
                "serverPublicKey": "public-key",
            ],
        ])
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
