import Foundation

public struct ViewerConnectionProfile: Codable, Equatable {
    public let rendezvousServer: String
    public let serverPublicKey: String
    public let peerID: String
    public let forceRelay: Bool

    public init(
        rendezvousServer: String,
        serverPublicKey: String,
        peerID: String,
        forceRelay: Bool = false
    ) {
        self.rendezvousServer = rendezvousServer
        self.serverPublicKey = serverPublicKey
        self.peerID = peerID
        self.forceRelay = forceRelay
    }
}

public final class ViewerConnectionProfileStore {
    private static let storageKey = "viewer.connection-profile.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ViewerConnectionProfile? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(ViewerConnectionProfile.self, from: data)
    }

    public func save(_ profile: ViewerConnectionProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }
}
