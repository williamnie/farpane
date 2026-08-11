@testable import ConnectionCatalog
import Darwin
import Foundation
import XCTest

final class HostAgentBootstrapPublicationCoordinatorTests: XCTestCase {
    func testPublishesFirstRevisionAndAdvancesOnlyForServerOrBuildChanges() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        )
        let firstCatalog = catalog(server: "one.example.invalid:21116")

        XCTAssertEqual(
            try coordinator.publish(catalog: firstCatalog, agentBuildID: "build-1"),
            HostAgentBootstrapPublicationOutcome(
                configRevision: 1,
                publicationResult: .published
            )
        )
        let viewerOnlyChange = DeviceCatalogDocument(
            server: ServerConfiguration(
                displayName: "viewer-only-name-change",
                rendezvousServer: "one.example.invalid:21116",
                serverPublicKey: "public-key",
                forceRelay: true
            ),
            devices: [SavedDevice(peerID: "viewer-only-device")]
        )
        XCTAssertEqual(
            try coordinator.publish(catalog: viewerOnlyChange, agentBuildID: "build-1"),
            HostAgentBootstrapPublicationOutcome(
                configRevision: 1,
                publicationResult: .unchanged
            )
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: catalog(server: "two.example.invalid:21116"),
                agentBuildID: "build-1"
            ).configRevision,
            2
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: catalog(server: "two.example.invalid:21116"),
                agentBuildID: "build-2"
            ).configRevision,
            3
        )
        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: fixture.applicationSupport
            )
        ).load()
        XCTAssertEqual(configuration.configRevision, 3)
        XCTAssertEqual(configuration.agentBuildID, "build-2")
        XCTAssertEqual(configuration.rendezvousServer, "two.example.invalid:21116")
    }

    func testCorruptProjectionAndRevisionExhaustionPreserveExistingBytes() throws {
        let corrupt = try makeFixture()
        defer { try? FileManager.default.removeItem(at: corrupt.root) }
        let corruptCoordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: corrupt.applicationSupport
        )
        _ = try corruptCoordinator.publish(
            catalog: catalog(server: "one.example.invalid:21116"),
            agentBuildID: "build-1"
        )
        let corruptURL = projectionURL(applicationSupport: corrupt.applicationSupport)
        let corruptBytes = Data("{}".utf8)
        try corruptBytes.write(to: corruptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: corruptURL.path
        )
        XCTAssertThrowsError(
            try corruptCoordinator.publish(
                catalog: catalog(server: "two.example.invalid:21116"),
                agentBuildID: "build-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationError,
                .invalidDocument
            )
        }
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)

        let exhausted = try makeFixture()
        defer { try? FileManager.default.removeItem(at: exhausted.root) }
        let directory = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: exhausted.applicationSupport
        )
        let maximum = try HostAgentBootstrapProjectionBuilder.build(
            catalog: catalog(server: "one.example.invalid:21116"),
            configRevision: HostAgentBootstrapConfiguration.maximumConfigRevision,
            agentBuildID: "build-1"
        )
        _ = try HostAgentBootstrapConfigurationPublisher(
            directoryURL: directory
        ).publish(maximum)
        let maximumBytes = try Data(contentsOf: projectionURL(
            applicationSupport: exhausted.applicationSupport
        ))

        XCTAssertThrowsError(
            try HostAgentBootstrapPublicationCoordinator(
                applicationSupportURL: exhausted.applicationSupport
            ).publish(
                catalog: catalog(server: "two.example.invalid:21116"),
                agentBuildID: "build-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapPublicationCoordinatorError,
                .revisionExhausted(HostAgentBootstrapConfiguration.maximumConfigRevision)
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: projectionURL(applicationSupport: exhausted.applicationSupport)),
            maximumBytes
        )
    }

    func testPublicationBusyDoesNotAdvanceDurableProjection() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        )
        _ = try coordinator.publish(
            catalog: catalog(server: "one.example.invalid:21116"),
            agentBuildID: "build-1"
        )
        let directory = HostAgentBootstrapProductLayout.directoryURL(
            applicationSupportURL: fixture.applicationSupport
        )
        let lockURL = directory.appendingPathComponent(
            HostAgentBootstrapConfigurationPublisher.publicationLockFileName
        )
        let descriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(
            try coordinator.publish(
                catalog: catalog(server: "two.example.invalid:21116"),
                agentBuildID: "build-1"
            )
        ) { error in
            XCTAssertEqual(
                error as? HostAgentBootstrapConfigurationPublisherError,
                .publicationBusy
            )
        }
        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: directory
        ).load()
        XCTAssertEqual(configuration.configRevision, 1)
        XCTAssertEqual(configuration.rendezvousServer, "one.example.invalid:21116")
    }

    func testClipboardPolicyChangesAdvanceRevisionAndRemainDirectional() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        )
        let source = catalog(server: "one.example.invalid:21116")

        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                clipboardPolicy: .disabled
            ).configRevision,
            1
        )
        let readOnly = HostAgentClipboardPolicy(
            allowRemoteRead: true,
            allowRemoteWrite: false
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                clipboardPolicy: readOnly
            ).configRevision,
            2
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                clipboardPolicy: readOnly
            ).publicationResult,
            .unchanged
        )
        let smallReadAndRichWrite = HostAgentClipboardPolicy(
            allowRemoteRead: true,
            allowRemoteWrite: false,
            allowRemoteRichTextRead: false,
            allowRemoteRichTextWrite: true
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                clipboardPolicy: smallReadAndRichWrite
            ).configRevision,
            3
        )
        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: fixture.applicationSupport
            )
        ).load()
        XCTAssertEqual(configuration.schemaVersion, 6)
        XCTAssertEqual(configuration.clipboardPolicy, smallReadAndRichWrite)
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        let imageRead = HostAgentClipboardPolicy(
            allowRemoteRead: true,
            allowRemoteWrite: false,
            allowRemoteRichTextRead: false,
            allowRemoteRichTextWrite: true,
            allowRemoteImageRead: true,
            allowRemoteImageWrite: false
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                clipboardPolicy: imageRead
            ).configRevision,
            4
        )
        let imageConfiguration = try HostAgentBootstrapConfigurationReader(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: fixture.applicationSupport
            )
        ).load()
        XCTAssertEqual(imageConfiguration.schemaVersion, 6)
        XCTAssertEqual(imageConfiguration.clipboardPolicy, imageRead)
        XCTAssertEqual(imageConfiguration.fileTransferPolicy, .disabled)
    }

    func testFileTransferPolicyChangesAdvanceRevisionAndRemainExact() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        )
        let source = catalog(server: "one.example.invalid:21116")

        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1"
            ).configRevision,
            1
        )
        let enabled = HostAgentFileTransferPolicy(
            enabled: true,
            receiveRoot: "/Users/example/FarPane Receive"
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                fileTransferPolicy: enabled
            ).configRevision,
            2
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                fileTransferPolicy: enabled
            ).publicationResult,
            .unchanged
        )
        let changedRoot = HostAgentFileTransferPolicy(
            enabled: true,
            receiveRoot: "/Users/example/Another FarPane Receive"
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                fileTransferPolicy: changedRoot
            ).configRevision,
            3
        )
        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: fixture.applicationSupport
            )
        ).load()
        XCTAssertEqual(configuration.fileTransferPolicy, changedRoot)
        XCTAssertEqual(configuration.clipboardPolicy, .disabled)
    }

    func testAudioPolicyChangesAdvanceRevisionAndRemainExact() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let coordinator = HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        )
        let source = catalog(server: "one.example.invalid:21116")

        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1"
            ).configRevision,
            1
        )
        let enabled = HostAgentAudioPolicy(enabled: true)
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                audioPolicy: enabled
            ).configRevision,
            2
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                audioPolicy: enabled
            ).publicationResult,
            .unchanged
        )
        XCTAssertEqual(
            try coordinator.publish(
                catalog: source,
                agentBuildID: "build-1",
                audioPolicy: .disabled
            ).configRevision,
            3
        )
        let configuration = try HostAgentBootstrapConfigurationReader(
            directoryURL: HostAgentBootstrapProductLayout.directoryURL(
                applicationSupportURL: fixture.applicationSupport
            )
        ).load()
        XCTAssertEqual(configuration.schemaVersion, 6)
        XCTAssertEqual(configuration.audioPolicy, .disabled)
        XCTAssertEqual(configuration.fileTransferPolicy, .disabled)
        XCTAssertEqual(configuration.clipboardPolicy, .disabled)
    }

    func testLegacySchemaOnePublicationUpgradesWithClipboardDisabled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: fixture.applicationSupport
        )
        let legacy = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "configRevision": 7,
                "agentBuildID": "build-1",
                "server": [
                    "rendezvousServer": "one.example.invalid:21116",
                    "serverPublicKey": "public-key",
                ],
            ],
            options: [.sortedKeys]
        )
        _ = try HostAgentBootstrapConfigurationPublisher(
            directoryURL: directory
        ).publish(legacy)

        let outcome = try HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        ).publish(
            catalog: catalog(server: "one.example.invalid:21116"),
            agentBuildID: "build-1",
            clipboardPolicy: .disabled
        )

        XCTAssertEqual(outcome.configRevision, 8)
        let upgraded = try HostAgentBootstrapConfigurationReader(
            directoryURL: directory
        ).load()
        XCTAssertEqual(upgraded.schemaVersion, 6)
        XCTAssertEqual(upgraded.clipboardPolicy, .disabled)
        XCTAssertEqual(upgraded.fileTransferPolicy, .disabled)
    }

    func testSchemaTwoPublicationUpgradesWithRichTextDisabled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: fixture.applicationSupport
        )
        let schemaTwo = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 2,
                "configRevision": 4,
                "agentBuildID": "build-1",
                "server": [
                    "rendezvousServer": "one.example.invalid:21116",
                    "serverPublicKey": "public-key",
                ],
                "clipboard": [
                    "allowRemoteRead": true,
                    "allowRemoteWrite": false,
                ],
            ],
            options: [.sortedKeys]
        )
        _ = try HostAgentBootstrapConfigurationPublisher(
            directoryURL: directory
        ).publish(schemaTwo)

        let policy = HostAgentClipboardPolicy(
            allowRemoteRead: true,
            allowRemoteWrite: false
        )
        let outcome = try HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        ).publish(
            catalog: catalog(server: "one.example.invalid:21116"),
            agentBuildID: "build-1",
            clipboardPolicy: policy
        )

        XCTAssertEqual(outcome.configRevision, 5)
        let upgraded = try HostAgentBootstrapConfigurationReader(
            directoryURL: directory
        ).load()
        XCTAssertEqual(upgraded.schemaVersion, 6)
        XCTAssertEqual(upgraded.clipboardPolicy, policy)
        XCTAssertEqual(upgraded.fileTransferPolicy, .disabled)
        XCTAssertFalse(upgraded.clipboardPolicy.allowRemoteRichTextRead)
        XCTAssertFalse(upgraded.clipboardPolicy.allowRemoteRichTextWrite)
        XCTAssertFalse(upgraded.clipboardPolicy.allowRemoteImageRead)
        XCTAssertFalse(upgraded.clipboardPolicy.allowRemoteImageWrite)
    }

    func testSchemaThreePublicationUpgradesWithImageDisabled() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = try HostAgentBootstrapProductDirectoryPreparer.prepare(
            applicationSupportURL: fixture.applicationSupport
        )
        let schemaThree = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 3,
                "configRevision": 9,
                "agentBuildID": "build-1",
                "server": [
                    "rendezvousServer": "one.example.invalid:21116",
                    "serverPublicKey": "public-key",
                ],
                "clipboard": [
                    "allowRemoteRead": false,
                    "allowRemoteWrite": true,
                    "allowRemoteRichTextRead": true,
                    "allowRemoteRichTextWrite": false,
                ],
            ],
            options: [.sortedKeys]
        )
        _ = try HostAgentBootstrapConfigurationPublisher(
            directoryURL: directory
        ).publish(schemaThree)

        let policy = HostAgentClipboardPolicy(
            allowRemoteRead: false,
            allowRemoteWrite: true,
            allowRemoteRichTextRead: true,
            allowRemoteRichTextWrite: false
        )
        let outcome = try HostAgentBootstrapPublicationCoordinator(
            applicationSupportURL: fixture.applicationSupport
        ).publish(
            catalog: catalog(server: "one.example.invalid:21116"),
            agentBuildID: "build-1",
            clipboardPolicy: policy
        )

        XCTAssertEqual(outcome.configRevision, 10)
        let upgraded = try HostAgentBootstrapConfigurationReader(
            directoryURL: directory
        ).load()
        XCTAssertEqual(upgraded.schemaVersion, 6)
        XCTAssertEqual(upgraded.clipboardPolicy, policy)
        XCTAssertEqual(upgraded.fileTransferPolicy, .disabled)
        XCTAssertFalse(upgraded.clipboardPolicy.allowRemoteImageRead)
        XCTAssertFalse(upgraded.clipboardPolicy.allowRemoteImageWrite)
    }

    private func catalog(server: String) -> DeviceCatalogDocument {
        DeviceCatalogDocument(
            server: ServerConfiguration(
                displayName: "test",
                rendezvousServer: server,
                serverPublicKey: "public-key"
            )
        )
    }

    private func makeFixture() throws -> (root: URL, applicationSupport: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostAgentBootstrapCoordinatorTests-\(UUID().uuidString)")
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

    private func projectionURL(applicationSupport: URL) -> URL {
        HostAgentBootstrapProductLayout.directoryURL(
            applicationSupportURL: applicationSupport
        ).appendingPathComponent(
            HostAgentBootstrapConfigurationReader.configurationFileName
        )
    }
}
