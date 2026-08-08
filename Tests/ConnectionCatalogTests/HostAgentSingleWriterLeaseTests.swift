@testable import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentSingleWriterLeaseTests: XCTestCase {
    func testRecordDecoderRejectsUnknownOrNonCanonicalDocuments() throws {
        let bootID = UUID()
        let valid: [String: Any] = [
            "schemaVersion": 1,
            "agentBootID": bootID.uuidString,
            "agentBuildID": "build-1",
            "configRevision": 1,
        ]
        var unknown = valid
        unknown["server"] = "must-not-enter-lease"
        var lowercasedBootID = valid
        lowercasedBootID["agentBootID"] = bootID.uuidString.lowercased()
        var booleanRevision = valid
        booleanRevision["configRevision"] = true

        for document in [unknown, lowercasedBootID, booleanRevision] {
            XCTAssertThrowsError(
                try HostAgentSingleWriterLeaseRecord.decode(data(document))
            ) { error in
                XCTAssertEqual(
                    error as? HostAgentSingleWriterLeaseRecordError,
                    .invalidDocument
                )
            }
        }

        var future = valid
        future["schemaVersion"] = 2
        XCTAssertThrowsError(
            try HostAgentSingleWriterLeaseRecord.decode(data(future))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentSingleWriterLeaseRecordError,
                .unsupportedSchema(2)
            )
        }
        XCTAssertThrowsError(
            try HostAgentSingleWriterLeaseRecord.decode(Data(
                repeating: 0,
                count: HostAgentSingleWriterLeaseRecord.maximumDocumentBytes + 1
            ))
        ) { error in
            XCTAssertEqual(
                error as? HostAgentSingleWriterLeaseRecordError,
                .documentTooLarge
            )
        }
    }

    func testAcquiresFixedLeaseAndWritesStrictNonSecretRecord() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bootID = UUID()
        let lease = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: try configuration(revision: 7, buildID: "build-7"),
            agentBootID: bootID
        )
        defer { lease.release() }

        XCTAssertEqual(
            lease.record,
            HostAgentSingleWriterLeaseRecord(
                agentBootID: bootID,
                agentBuildID: "build-7",
                configRevision: 7
            )
        )
        let leaseURL = fixture.directory.appendingPathComponent(
            HostAgentSingleWriterLease.leaseFileName
        )
        let data = try Data(contentsOf: leaseURL)
        XCTAssertEqual(
            try HostAgentSingleWriterLeaseRecord.decode(data),
            lease.record
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(json.keys),
            Set(["schemaVersion", "agentBootID", "agentBuildID", "configRevision"])
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: leaseURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in ["rendezvous", "serverPublicKey", "password", "token"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }

    func testConcurrentAcquireFailsAndPreservesLiveLeaseRecord() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: try configuration(revision: 7, buildID: "build-7"),
            agentBootID: UUID()
        )
        defer { first.release() }
        let leaseURL = fixture.directory.appendingPathComponent(
            HostAgentSingleWriterLease.leaseFileName
        )
        let liveBytes = try Data(contentsOf: leaseURL)

        XCTAssertThrowsError(
            try HostAgentSingleWriterLease.acquire(
                directoryURL: fixture.directory,
                configuration: try configuration(revision: 8, buildID: "build-8"),
                agentBootID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentSingleWriterLeaseError,
                .alreadyHeld
            )
        }
        XCTAssertEqual(try Data(contentsOf: leaseURL), liveBytes)
    }

    func testReleaseIsIdempotentAndAllowsCrashRecordReplacement() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: try configuration(revision: 7, buildID: "build-7"),
            agentBootID: UUID()
        )
        first.release()
        first.release()

        let nextBootID = UUID()
        let second = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: try configuration(revision: 8, buildID: "build-8"),
            agentBootID: nextBootID
        )
        defer { second.release() }
        XCTAssertEqual(
            second.record,
            HostAgentSingleWriterLeaseRecord(
                agentBootID: nextBootID,
                agentBuildID: "build-8",
                configRevision: 8
            )
        )
        let data = try Data(contentsOf: fixture.directory.appendingPathComponent(
            HostAgentSingleWriterLease.leaseFileName
        ))
        XCTAssertEqual(
            try HostAgentSingleWriterLeaseRecord.decode(data),
            second.record
        )
    }

    func testDeinitReleasesLease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            let lease = try HostAgentSingleWriterLease.acquire(
                directoryURL: fixture.directory,
                configuration: try configuration(revision: 1, buildID: "build-1"),
                agentBootID: UUID()
            )
            withExtendedLifetime(lease) {}
        }

        let replacement = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: try configuration(revision: 1, buildID: "build-1"),
            agentBootID: UUID()
        )
        replacement.release()
    }

    func testRejectsInsecureExistingLeaseFilesWithoutChangingTargets() throws {
        try assertInsecureLeaseFile { fixture, leaseURL in
            let bytes = Data("wide-mode".utf8)
            try bytes.write(to: leaseURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: leaseURL.path
            )
            return (leaseURL, bytes)
        }
        try assertInsecureLeaseFile { fixture, leaseURL in
            let target = fixture.root.appendingPathComponent("symlink-target")
            let bytes = Data("symlink-target".utf8)
            try bytes.write(to: target)
            try FileManager.default.createSymbolicLink(
                at: leaseURL,
                withDestinationURL: target
            )
            return (target, bytes)
        }
        try assertInsecureLeaseFile { fixture, leaseURL in
            let target = fixture.root.appendingPathComponent("hardlink-target")
            let bytes = Data("hardlink-target".utf8)
            try bytes.write(to: target)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: target.path
            )
            try FileManager.default.linkItem(at: target, to: leaseURL)
            return (target, bytes)
        }
    }

    private func assertInsecureLeaseFile(
        prepare: (Fixture, URL) throws -> (protectedURL: URL, expectedBytes: Data)
    ) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leaseURL = fixture.directory.appendingPathComponent(
            HostAgentSingleWriterLease.leaseFileName
        )
        let protected = try prepare(fixture, leaseURL)

        XCTAssertThrowsError(
            try HostAgentSingleWriterLease.acquire(
                directoryURL: fixture.directory,
                configuration: try configuration(revision: 1, buildID: "build-1"),
                agentBootID: UUID()
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentSingleWriterLeaseError,
                .insecureLeaseFile
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: protected.protectedURL),
            protected.expectedBytes
        )
    }

    private func configuration(
        revision: UInt64,
        buildID: String
    ) throws -> HostAgentBootstrapConfiguration {
        let data = try HostAgentBootstrapProjectionBuilder.build(
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
        return try HostAgentBootstrapConfiguration.decode(data)
    }

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HostAgentSingleWriterLeaseTests-\(UUID().uuidString)",
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
        return Fixture(root: root, directory: directory)
    }
}

private struct Fixture {
    let root: URL
    let directory: URL
}
