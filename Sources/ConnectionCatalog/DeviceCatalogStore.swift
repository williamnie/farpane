import Foundation

public enum DeviceCatalogStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case corruptDocument
    case invalidDocument
    case ioFailure
}

public final class DeviceCatalogStore: @unchecked Sendable {
    public let fileURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL = DeviceCatalogStore.defaultFileURL(),
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("RustDesk Native Viewer", isDirectory: true)
            .appendingPathComponent("catalog-v1.json", isDirectory: false)
    }

    public var exists: Bool {
        fileManager.fileExists(atPath: fileURL.path)
    }

    public func load() throws -> DeviceCatalogDocument {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return DeviceCatalogDocument()
            }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw DeviceCatalogStoreError.ioFailure
            }
            let document: DeviceCatalogDocument
            do {
                document = try decoder.decode(DeviceCatalogDocument.self, from: data)
            } catch {
                throw DeviceCatalogStoreError.corruptDocument
            }
            guard document.schemaVersion == DeviceCatalogDocument.currentSchemaVersion else {
                throw DeviceCatalogStoreError.unsupportedSchema(document.schemaVersion)
            }
            guard document.devices.allSatisfy({ !DeviceCatalogDocument.normalize($0.peerID).isEmpty }) else {
                throw DeviceCatalogStoreError.invalidDocument
            }
            return document
        }
    }

    public func save(_ document: DeviceCatalogDocument) throws {
        try lock.withLock {
            guard document.schemaVersion == DeviceCatalogDocument.currentSchemaVersion else {
                throw DeviceCatalogStoreError.unsupportedSchema(document.schemaVersion)
            }
            guard document.devices.allSatisfy({ !DeviceCatalogDocument.normalize($0.peerID).isEmpty }) else {
                throw DeviceCatalogStoreError.invalidDocument
            }
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try encoder.encode(document)
                try data.write(to: fileURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            } catch let error as DeviceCatalogStoreError {
                throw error
            } catch {
                throw DeviceCatalogStoreError.ioFailure
            }
        }
    }

    public func backupCorruptDocument(at date: Date = Date()) throws -> URL? {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("catalog-v1.corrupt-\(formatter.string(from: date)).json")
            do {
                try fileManager.copyItem(at: fileURL, to: backupURL)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: backupURL.path
                )
                return backupURL
            } catch {
                throw DeviceCatalogStoreError.ioFailure
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
