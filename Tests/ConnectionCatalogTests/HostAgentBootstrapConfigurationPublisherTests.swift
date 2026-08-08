@testable import ConnectionCatalog
import Darwin
import Foundation
import XCTest

final class HostAgentBootstrapConfigurationPublisherTests: XCTestCase {
    func testUsesTheExistingProductCatalogRootForASeparateAgentProjection() throws {
        let applicationSupport = URL(
            fileURLWithPath: "/Users/example/Library/Application Support",
            isDirectory: true
        )

        XCTAssertEqual(
            HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: applicationSupport
            ).path,
            "/Users/example/Library/Application Support/RustDesk Native Viewer/HostAgent"
        )
    }

    func testPublishesAtomicallyAndTreatsAnExactRetryAsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publisher = HostAgentBootstrapConfigurationPublisher(
            directoryURL: fixture.directory
        )
        let revision7 = try document(revision: 7, server: "one.example.invalid:21116")

        XCTAssertEqual(try publisher.publish(revision7), .published)
        let firstAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.configuration.path
        )
        XCTAssertEqual(
            try HostAgentBootstrapConfigurationReader(
                directoryURL: fixture.directory
            ).load().configRevision,
            7
        )
        XCTAssertEqual(
            (firstAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        XCTAssertEqual(try publisher.publish(revision7), .unchanged)

        let revision8 = try document(revision: 8, server: "two.example.invalid:21116")
        XCTAssertEqual(try publisher.publish(revision8), .published)
        let secondAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.configuration.path
        )
        XCTAssertNotEqual(
            firstAttributes[.systemFileNumber] as? NSNumber,
            secondAttributes[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(
            try HostAgentBootstrapConfigurationReader(
                directoryURL: fixture.directory
            ).load().configRevision,
            8
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(),
            [
                HostAgentBootstrapConfigurationPublisher.publicationLockFileName,
                HostAgentBootstrapConfigurationReader.configurationFileName,
            ]
        )
    }

    func testRejectsRevisionRollbackAndSameRevisionMutationWithoutReplacingCurrent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let publisher = HostAgentBootstrapConfigurationPublisher(
            directoryURL: fixture.directory
        )
        let current = try document(revision: 7, server: "one.example.invalid:21116")
        _ = try publisher.publish(current)
        let original = try Data(contentsOf: fixture.configuration)

        XCTAssertThrowsError(
            try publisher.publish(document(revision: 6, server: "old.example.invalid:21116"))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationPublisherError,
                .nonMonotonicRevision(current: 7, proposed: 6)
            )
        }
        XCTAssertThrowsError(
            try publisher.publish(document(revision: 7, server: "mutated.example.invalid:21116"))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationPublisherError,
                .nonMonotonicRevision(current: 7, proposed: 7)
            )
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configuration), original)
    }

    func testInvalidInputAndInsecurePublicationLockFailClosed() throws {
        let invalidFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: invalidFixture.root) }
        let invalidPublisher = HostAgentBootstrapConfigurationPublisher(
            directoryURL: invalidFixture.directory
        )
        XCTAssertThrowsError(try invalidPublisher.publish(Data("{}".utf8))) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidFixture.configuration.path))

        let lockFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: lockFixture.root) }
        let external = lockFixture.root.appendingPathComponent("external.lock")
        try Data().write(to: external)
        try FileManager.default.createSymbolicLink(
            at: lockFixture.directory.appendingPathComponent(
                HostAgentBootstrapConfigurationPublisher.publicationLockFileName
            ),
            withDestinationURL: external
        )
        XCTAssertThrowsError(
            try HostAgentBootstrapConfigurationPublisher(
                directoryURL: lockFixture.directory
            ).publish(document(revision: 1, server: "one.example.invalid:21116"))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationPublisherError,
                .insecurePublicationLock
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockFixture.configuration.path))
    }

    func testConcurrentPublisherFailsClosedWhilePublicationLockIsHeld() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lockURL = fixture.directory.appendingPathComponent(
            HostAgentBootstrapConfigurationPublisher.publicationLockFileName
        )
        try Data().write(to: lockURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lockURL.path
        )
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(
            try HostAgentBootstrapConfigurationPublisher(
                directoryURL: fixture.directory
            ).publish(document(revision: 1, server: "one.example.invalid:21116"))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationPublisherError,
                .publicationBusy
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configuration.path))
    }

    private func makeFixture() throws -> (
        root: URL,
        directory: URL,
        configuration: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostAgentBootstrapPublisherTests-\(UUID().uuidString)", isDirectory: true)
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
                HostAgentBootstrapConfigurationReader.configurationFileName
            )
        )
    }

    private func document(revision: UInt64, server: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "configRevision": revision,
            "agentBuildID": "20260808155349",
            "server": [
                "rendezvousServer": server,
                "serverPublicKey": "public-key",
            ],
        ], options: [.sortedKeys])
    }
}
