@testable import ConnectionCatalog
import Foundation
import XCTest

final class HostAgentRuntimeConfigurationCoherenceTests: XCTestCase {
    func testSecureReaderCorrelatesFixedBootstrapAndLeaseWithoutMutation() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let configuration = try configuration(revision: 7, buildID: "build-7")
        try write(configuration: configuration, to: fixture.directory)
        let bootID = UUID()
        let lease = try HostAgentSingleWriterLease.acquire(
            directoryURL: fixture.directory,
            configuration: configuration,
            agentBootID: bootID
        )
        defer { lease.release() }
        let leaseURL = fixture.directory.appendingPathComponent(
            HostAgentSingleWriterLease.leaseFileName
        )
        let bootstrapURL = fixture.directory.appendingPathComponent(
            HostAgentBootstrapConfigurationReader.configurationFileName
        )
        let bytesBefore = try (
            bootstrap: Data(contentsOf: bootstrapURL),
            lease: Data(contentsOf: leaseURL)
        )

        let observation = try HostAgentRuntimeConfigurationObservationReader(
            directoryURL: fixture.directory
        ).load()

        XCTAssertEqual(observation.bootstrap, configuration)
        XCTAssertEqual(observation.lease, lease.record)
        XCTAssertEqual(try Data(contentsOf: bootstrapURL), bytesBefore.bootstrap)
        XCTAssertEqual(try Data(contentsOf: leaseURL), bytesBefore.lease)
        XCTAssertEqual(
            HostAgentRuntimeConfigurationCoherencePolicy.evaluate(
                observation: observation,
                liveAgentBuildID: "build-7",
                liveAgentBootID: bootID.uuidString.lowercased()
            ),
            .coherent(configRevision: 7)
        )
    }

    func testPolicyFailsClosedForStaleRevisionBeforeIdentityChecks() throws {
        let bootID = UUID()
        let observation = HostAgentRuntimeConfigurationObservation(
            bootstrap: try configuration(revision: 8, buildID: "build-8"),
            lease: HostAgentSingleWriterLeaseRecord(
                agentBootID: bootID,
                agentBuildID: "build-7",
                configRevision: 7
            )
        )

        XCTAssertEqual(
            HostAgentRuntimeConfigurationCoherencePolicy.evaluate(
                observation: observation,
                liveAgentBuildID: "wrong-build",
                liveAgentBootID: UUID().uuidString.lowercased()
            ),
            .staleConfiguration(
                expectedRevision: 8,
                runningRevision: 7
            )
        )
    }

    func testPolicyRejectsBootstrapLeaseBuildAndLivePeerIdentityMismatch()
        throws
    {
        let bootID = UUID()
        let configuration = try configuration(revision: 7, buildID: "build-7")
        let validLease = HostAgentSingleWriterLeaseRecord(
            agentBootID: bootID,
            agentBuildID: "build-7",
            configRevision: 7
        )

        let cases: [(
            HostAgentRuntimeConfigurationObservation,
            String,
            String
        )] = [
            (
                HostAgentRuntimeConfigurationObservation(
                    bootstrap: configuration,
                    lease: HostAgentSingleWriterLeaseRecord(
                        agentBootID: bootID,
                        agentBuildID: "other-build",
                        configRevision: 7
                    )
                ),
                "other-build",
                bootID.uuidString.lowercased()
            ),
            (
                HostAgentRuntimeConfigurationObservation(
                    bootstrap: configuration,
                    lease: validLease
                ),
                "other-build",
                bootID.uuidString.lowercased()
            ),
            (
                HostAgentRuntimeConfigurationObservation(
                    bootstrap: configuration,
                    lease: validLease
                ),
                "build-7",
                UUID().uuidString.lowercased()
            ),
            (
                HostAgentRuntimeConfigurationObservation(
                    bootstrap: configuration,
                    lease: validLease
                ),
                "build-7",
                bootID.uuidString
            ),
        ]

        for (observation, buildID, liveBootID) in cases {
            XCTAssertEqual(
                HostAgentRuntimeConfigurationCoherencePolicy.evaluate(
                    observation: observation,
                    liveAgentBuildID: buildID,
                    liveAgentBootID: liveBootID
                ),
                .identityMismatch
            )
        }
    }

    func testReaderRejectsMissingSymlinkLooseAndMalformedLease() throws {
        try assertLeaseRejected(
            prepareLease: { _ in },
            expected: .leaseUnavailable
        )
        try assertLeaseRejected(
            prepareLease: { fixture in
                let target = fixture.root.appendingPathComponent("external")
                try Data("external".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(
                    at: fixture.lease,
                    withDestinationURL: target
                )
            },
            expected: .insecureLeaseFile
        )
        try assertLeaseRejected(
            prepareLease: { fixture in
                try Data("loose".utf8).write(to: fixture.lease)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: fixture.lease.path
                )
            },
            expected: .insecureLeaseFile
        )
        try assertLeaseRejected(
            prepareLease: { fixture in
                let target = fixture.root.appendingPathComponent(
                    "hard-link-target"
                )
                try Data("hard-link".utf8).write(to: target)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: target.path
                )
                try FileManager.default.linkItem(
                    at: target,
                    to: fixture.lease
                )
            },
            expected: .insecureLeaseFile
        )

        let malformed = try makeFixture()
        defer { try? FileManager.default.removeItem(at: malformed.root) }
        try write(
            configuration: configuration(revision: 1, buildID: "build-1"),
            to: malformed.directory
        )
        try Data("not-json".utf8).write(to: malformed.lease)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: malformed.lease.path
        )
        XCTAssertThrowsError(
            try HostAgentRuntimeConfigurationObservationReader(
                directoryURL: malformed.directory
            ).load()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentSingleWriterLeaseRecordError,
                .invalidDocument
            )
        }
    }

    func testProductAppUsesCoherentProjectionForReadinessPresentationAndDispatch()
        throws
    {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/RustDeskNative/RustDeskNativeApp.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(
            "refreshHostAgentRuntimeConfigurationCoherence()\n"
                + "        projectHostAgentBackgroundCommandPresentation("
        ))
        XCTAssertTrue(source.contains(
            "phase: coherentHostAgentBackgroundActivationView?.phase"
        ))
        XCTAssertTrue(source.contains(
            "projection:\n"
                + "                    coherentHostAgentBackgroundActivationView?.projection"
        ))
        XCTAssertTrue(source.contains(
            "hostAgentRuntimeConfigurationCoherence\n"
                + "            .permitsRuntimeProjection"
        ))
        XCTAssertTrue(source.contains(
            "guard case .ready(let publishedConfigRevision) =\n"
                + "            hostAgentBootstrapState"
        ))
        XCTAssertTrue(source.contains(
            "observation.bootstrap.configRevision ==\n"
                + "                publishedConfigRevision"
        ))
        XCTAssertTrue(source.contains(
            "available.peerIdentity.agentBuildID"
        ))
        XCTAssertTrue(source.contains(
            "available.peerIdentity.agentBootID"
        ))
        XCTAssertFalse(source.contains(
            "phase: hostAgentBackgroundActivationView?.phase"
        ))
    }

    private func assertLeaseRejected(
        prepareLease: (Fixture) throws -> Void,
        expected: HostAgentRuntimeConfigurationObservationError
    ) throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try write(
            configuration: configuration(revision: 1, buildID: "build-1"),
            to: fixture.directory
        )
        try prepareLease(fixture)

        XCTAssertThrowsError(
            try HostAgentRuntimeConfigurationObservationReader(
                directoryURL: fixture.directory
            ).load()
        ) { error in
            XCTAssertEqual(
                error as? HostAgentRuntimeConfigurationObservationError,
                expected
            )
        }
    }

    private func configuration(
        revision: UInt64,
        buildID: String
    ) throws -> HostAgentBootstrapConfiguration {
        try HostAgentBootstrapConfiguration.decode(
            HostAgentBootstrapProjectionBuilder.build(
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
        )
    }

    private func write(
        configuration: HostAgentBootstrapConfiguration,
        to directory: URL
    ) throws {
        let data = try HostAgentBootstrapProjectionBuilder.build(
            catalog: DeviceCatalogDocument(
                server: ServerConfiguration(
                    displayName: "test",
                    rendezvousServer: configuration.rendezvousServer,
                    serverPublicKey: configuration.serverPublicKey
                )
            ),
            configRevision: configuration.configRevision,
            agentBuildID: configuration.agentBuildID
        )
        let url = directory.appendingPathComponent(
            HostAgentBootstrapConfigurationReader.configurationFileName
        )
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HostAgentRuntimeConfigurationCoherenceTests-"
                    + UUID().uuidString,
                isDirectory: true
            )
        let directory = root.appendingPathComponent(
            "HostAgent",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return Fixture(
            root: root,
            directory: directory,
            lease: directory.appendingPathComponent(
                HostAgentSingleWriterLease.leaseFileName
            )
        )
    }
}

private struct Fixture {
    let root: URL
    let directory: URL
    let lease: URL
}
