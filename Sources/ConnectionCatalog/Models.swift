import Foundation

public enum DeviceSource: String, Codable, Sendable {
    case user
    case migratedLegacy
}

public struct ServerConfiguration: Codable, Equatable, Sendable {
    public var displayName: String
    public var rendezvousServer: String
    public var serverPublicKey: String
    public var forceRelay: Bool

    public init(
        displayName: String,
        rendezvousServer: String,
        serverPublicKey: String,
        forceRelay: Bool = false
    ) {
        self.displayName = displayName
        self.rendezvousServer = rendezvousServer
        self.serverPublicKey = serverPublicKey
        self.forceRelay = forceRelay
    }

    public var isComplete: Bool {
        !rendezvousServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !serverPublicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct SavedDevice: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var peerID: String
    public var displayName: String?
    public var isFavorite: Bool
    public let createdAt: Date
    public var lastSuccessfulConnectionAt: Date?
    public var source: DeviceSource

    public init(
        id: UUID = UUID(),
        peerID: String,
        displayName: String? = nil,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        lastSuccessfulConnectionAt: Date? = nil,
        source: DeviceSource = .user
    ) {
        self.id = id
        self.peerID = peerID
        self.displayName = displayName
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.lastSuccessfulConnectionAt = lastSuccessfulConnectionAt
        self.source = source
    }

    public var resolvedDisplayName: String {
        let value = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? peerID : value
    }
}

public struct DeviceCatalogDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var server: ServerConfiguration?
    public var devices: [SavedDevice]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        server: ServerConfiguration? = nil,
        devices: [SavedDevice] = []
    ) {
        self.schemaVersion = schemaVersion
        self.server = server
        self.devices = devices
    }

    public func device(id: UUID) -> SavedDevice? {
        devices.first { $0.id == id }
    }

    public func device(peerID: String) -> SavedDevice? {
        let normalized = Self.normalize(peerID)
        return devices.first { Self.normalize($0.peerID) == normalized }
    }

    @discardableResult
    public mutating func recordAuthenticated(
        peerID: String,
        preferredID: UUID? = nil,
        at date: Date = Date()
    ) -> SavedDevice {
        let normalized = Self.normalize(peerID)
        if let index = devices.firstIndex(where: { Self.normalize($0.peerID) == normalized }) {
            devices[index].peerID = normalized
            devices[index].lastSuccessfulConnectionAt = date
            devices[index].source = .user
            return devices[index]
        }
        let device = SavedDevice(
            id: preferredID ?? UUID(),
            peerID: normalized,
            createdAt: date,
            lastSuccessfulConnectionAt: date,
            source: .user
        )
        devices.append(device)
        return device
    }

    public mutating func updateDevice(
        id: UUID,
        displayName: String? = nil,
        isFavorite: Bool? = nil
    ) -> Bool {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
        if let displayName {
            let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            devices[index].displayName = normalized.isEmpty ? nil : normalized
        }
        if let isFavorite { devices[index].isFavorite = isFavorite }
        return true
    }

    @discardableResult
    public mutating func removeDevice(id: UUID) -> SavedDevice? {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return nil }
        return devices.remove(at: index)
    }

    public var sortedDevices: [SavedDevice] {
        devices.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            switch (lhs.lastSuccessfulConnectionAt, rhs.lastSuccessfulConnectionAt) {
            case let (left?, right?):
                if left != right { return left > right }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.peerID.localizedStandardCompare(rhs.peerID) == .orderedAscending
        }
    }

    public static func normalize(_ peerID: String) -> String {
        peerID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
