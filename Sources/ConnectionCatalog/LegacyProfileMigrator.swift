import Foundation

public enum LegacyMigrationResult: Equatable {
    case noLegacyProfile
    case skippedCatalogExists
    case invalidLegacyProfilePreserved
    case migrated(SavedDevice)
}

public final class LegacyProfileMigrator {
    public static let storageKey = "viewer.connection-profile.v1"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func migrateIfNeeded(to store: DeviceCatalogStore) throws -> LegacyMigrationResult {
        guard !store.exists else { return .skippedCatalogExists }
        guard let data = defaults.data(forKey: Self.storageKey) else { return .noLegacyProfile }
        guard let profile = try? JSONDecoder().decode(LegacyProfile.self, from: data) else {
            return .invalidLegacyProfilePreserved
        }
        let peerID = DeviceCatalogDocument.normalize(profile.peerID)
        guard !peerID.isEmpty,
              !profile.rendezvousServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.serverPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalidLegacyProfilePreserved
        }

        let device = SavedDevice(peerID: peerID, source: .migratedLegacy)
        let document = DeviceCatalogDocument(
            server: ServerConfiguration(
                displayName: "自建服务器",
                rendezvousServer: profile.rendezvousServer,
                serverPublicKey: profile.serverPublicKey,
                forceRelay: profile.forceRelay
            ),
            devices: [device]
        )
        try store.save(document)
        defaults.removeObject(forKey: Self.storageKey)
        return .migrated(device)
    }
}

private struct LegacyProfile: Codable {
    let rendezvousServer: String
    let serverPublicKey: String
    let peerID: String
    let forceRelay: Bool
}
