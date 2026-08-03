import ConnectionCatalog
import Foundation
import XCTest

final class ConnectionCatalogTests: XCTestCase {
    func testCatalogRoundTripDoesNotPersistPasswordSentinel() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var document = DeviceCatalogDocument(
            server: ServerConfiguration(
                displayName: "自建服务器",
                rendezvousServer: "server.example.invalid:21116",
                serverPublicKey: "public-key"
            )
        )
        let saved = document.recordAuthenticated(peerID: "313 790 560", at: Date(timeIntervalSince1970: 10))
        XCTAssertTrue(document.updateDevice(id: saved.id, displayName: "工作室 Mac mini", isFavorite: true))

        try fixture.store.save(document)

        XCTAssertEqual(try fixture.store.load(), document)
        let persisted = try String(contentsOf: fixture.store.fileURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("one-time-password-sentinel"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.store.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAuthenticatedDeviceIsUniqueAndSortedByFavoriteThenRecency() {
        var document = DeviceCatalogDocument()
        let first = document.recordAuthenticated(peerID: " first ", at: Date(timeIntervalSince1970: 10))
        let second = document.recordAuthenticated(peerID: "second", at: Date(timeIntervalSince1970: 20))
        let updated = document.recordAuthenticated(peerID: "first", at: Date(timeIntervalSince1970: 30))
        XCTAssertTrue(document.updateDevice(id: second.id, isFavorite: true))

        XCTAssertEqual(first.id, updated.id)
        XCTAssertEqual(document.devices.count, 2)
        XCTAssertEqual(document.sortedDevices.map(\.id), [second.id, first.id])
        XCTAssertEqual(document.device(peerID: " first ")?.lastSuccessfulConnectionAt, Date(timeIntervalSince1970: 30))
    }

    func testLegacyMigrationIsSuccessfulAndIdempotent() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suite = "LegacyProfileMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy: [String: Any] = [
            "rendezvousServer": "server.example.invalid:21116",
            "serverPublicKey": "public-key",
            "peerID": "peer-id",
            "forceRelay": true,
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: LegacyProfileMigrator.storageKey)
        let migrator = LegacyProfileMigrator(defaults: defaults)

        let result = try migrator.migrateIfNeeded(to: fixture.store)

        guard case .migrated(let device) = result else { return XCTFail("migration did not run") }
        XCTAssertEqual(device.source, .migratedLegacy)
        XCTAssertNil(device.lastSuccessfulConnectionAt)
        XCTAssertNil(defaults.data(forKey: LegacyProfileMigrator.storageKey))
        XCTAssertEqual(try migrator.migrateIfNeeded(to: fixture.store), .skippedCatalogExists)
        XCTAssertEqual(try fixture.store.load().server?.forceRelay, true)
    }

    func testInvalidLegacyProfileIsPreserved() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suite = "LegacyProfileMigratorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: LegacyProfileMigrator.storageKey)

        XCTAssertEqual(
            try LegacyProfileMigrator(defaults: defaults).migrateIfNeeded(to: fixture.store),
            .invalidLegacyProfilePreserved
        )
        XCTAssertEqual(defaults.data(forKey: LegacyProfileMigrator.storageKey), corrupt)
        XCTAssertFalse(fixture.store.exists)
    }

    func testRejectsUnsupportedSchemaWithoutOverwritingIt() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\":2,\"devices\":[]}".utf8)
        try future.write(to: fixture.store.fileURL)

        XCTAssertThrowsError(try fixture.store.load()) { error in
            XCTAssertEqual(error as? DeviceCatalogStoreError, .unsupportedSchema(2))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), future)
    }

    func testKeychainRoundTripUsesAnIsolatedServiceAndLeavesNoItem() throws {
        let service = "io.rustdesknative.viewer.tests.\(UUID().uuidString)"
        let deviceID = UUID()
        let store = KeychainDeviceCredentialStore(service: service)
        defer { try? store.delete(deviceID: deviceID) }

        XCTAssertFalse(try store.contains(deviceID: deviceID))
        XCTAssertNil(try store.read(deviceID: deviceID))

        try store.upsert("first-test-password", deviceID: deviceID)
        XCTAssertTrue(try store.contains(deviceID: deviceID))
        XCTAssertEqual(try store.read(deviceID: deviceID), "first-test-password")

        try store.upsert("updated-test-password", deviceID: deviceID)
        XCTAssertEqual(try store.read(deviceID: deviceID), "updated-test-password")

        try store.delete(deviceID: deviceID)
        XCTAssertFalse(try store.contains(deviceID: deviceID))
    }

    func testBacksUpCorruptDocumentWithoutChangingOriginal() throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let corrupt = Data("corrupt-catalog".utf8)
        try corrupt.write(to: fixture.store.fileURL)

        let backup = try XCTUnwrap(fixture.store.backupCorruptDocument(at: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        XCTAssertEqual(try Data(contentsOf: fixture.store.fileURL), corrupt)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func makeFixture() -> (directory: URL, store: DeviceCatalogStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConnectionCatalogTests-\(UUID().uuidString)", isDirectory: true)
        let store = DeviceCatalogStore(fileURL: directory.appendingPathComponent("catalog-v1.json"))
        return (directory, store)
    }
}
