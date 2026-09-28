import CoreBridgeShim
import Foundation

public enum CoreFileTransferEventKind: UInt32, Equatable, Sendable {
    case progress = 1
    case waitingForConflict = 2
    case completed = 3
    case cancelled = 4
    case failed = 5
}

public enum CoreFileTransferFailure: UInt32, Equatable, Sendable {
    case none = 0
    case rejected = 1
    case unavailable = 2
    case protocolViolation = 3
    case localIO = 4
    case connectionClosed = 5
}

public struct CoreFileTransferEvent: Equatable, Sendable {
    public let sessionEpoch: UInt64
    public let transferID: Int32
    public let sequence: UInt64
    public let kind: CoreFileTransferEventKind
    public let failure: CoreFileTransferFailure
    public let currentFileNumber: Int?
    public let filesCompleted: UInt32
    public let totalFiles: UInt32
    public let bytesCompleted: UInt64
    public let totalBytes: UInt64
    public let bytesPerSecond: Double

    init?(
        sessionEpoch: UInt64, transferID: Int32, sequence: UInt64, kind: CoreFileTransferEventKind,
        failure: CoreFileTransferFailure, currentFileNumber: Int?, filesCompleted: UInt32,
        totalFiles: UInt32, bytesCompleted: UInt64, totalBytes: UInt64, bytesPerSecond: Double
    ) {
        guard sessionEpoch > 0, transferID > 0, sequence > 0, filesCompleted <= totalFiles,
            bytesCompleted <= totalBytes, bytesPerSecond.isFinite, bytesPerSecond >= 0,
            currentFileNumber.map({ $0 >= 0 && $0 < Int(totalFiles) }) ?? true
        else { return nil }

        switch kind {
        case .progress: guard failure == .none else { return nil }
        case .waitingForConflict:
            guard failure == .none, currentFileNumber != nil else { return nil }
        case .completed:
            guard failure == .none, currentFileNumber == nil, filesCompleted == totalFiles,
                bytesCompleted == totalBytes
            else { return nil }
        case .cancelled: guard failure == .none, currentFileNumber == nil else { return nil }
        case .failed: guard failure != .none, currentFileNumber == nil else { return nil }
        }

        self.sessionEpoch = sessionEpoch
        self.transferID = transferID
        self.sequence = sequence
        self.kind = kind
        self.failure = failure
        self.currentFileNumber = currentFileNumber
        self.filesCompleted = filesCompleted
        self.totalFiles = totalFiles
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct CoreFileTransferReceiveBlock: Equatable, Sendable {
    static let maximumFileCount = Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES)
    static let maximumPayloadBytes = Int(RDN_MAX_FILE_TRANSFER_BLOCK_BYTES)

    public let sessionEpoch: UInt64
    public let transferID: Int32
    public let fileNumber: UInt32
    public let payload: Data

    init?(sessionEpoch: UInt64, transferID: Int32, fileNumber: UInt32, payload: Data) {
        guard sessionEpoch > 0, transferID > 0, Int(fileNumber) < Self.maximumFileCount,
            !payload.isEmpty, payload.count <= Self.maximumPayloadBytes
        else { return nil }
        self.sessionEpoch = sessionEpoch
        self.transferID = transferID
        self.fileNumber = fileNumber
        self.payload = payload
    }
}

public enum CoreFileTransferListStatus: UInt32, Sendable {
    case success = 1
    case rejected = 2
    case unavailable = 3
}

public enum CoreFileTransferListEntryKind: UInt32, Sendable {
    case directory = 1
    case file = 2
}

public struct CoreFileTransferListEntry: Equatable, Sendable {
    public let kind: CoreFileTransferListEntryKind
    public let relativePath: String
    public let size: UInt64
    public let modifiedTime: UInt64

}

public struct CoreFileTransferListEvent: Equatable, Sendable {
    public let sessionEpoch: UInt64
    public let requestID: Int32
    public let status: CoreFileTransferListStatus
    public let entries: [CoreFileTransferListEntry]

    init?(
        sessionEpoch: UInt64, requestID: Int32, status: CoreFileTransferListStatus,
        entries: [CoreFileTransferListEntry]
    ) {
        guard sessionEpoch > 0, requestID > 0 else { return nil }
        if status != .success { guard entries.isEmpty else { return nil } }
        guard entries.count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES) else { return nil }

        var metadataBytes = 0
        var collisionKeys = Set<String>()
        for entry in entries {
            let nextMetadata = metadataBytes.addingReportingOverflow(entry.relativePath.utf8.count)
            guard !nextMetadata.overflow,
                nextMetadata.partialValue <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                ViewerFileTransferManifest.accepts(relativePath: entry.relativePath),
                !entry.relativePath.contains("/"), !entry.relativePath.contains("\\"),
                entry.relativePath.rangeOfCharacter(from: .controlCharacters) == nil,
                entry.kind != .directory || entry.size == 0
            else { return nil }
            let collisionKey = entry.relativePath.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard collisionKeys.insert(collisionKey).inserted else { return nil }
            metadataBytes = nextMetadata.partialValue
        }
        self.sessionEpoch = sessionEpoch
        self.requestID = requestID
        self.status = status
        self.entries = entries
    }
}

public enum CoreFileTransferManifestPartKind: UInt32, Sendable {
    case files = 1
    case emptyDirectories = 2
}

public struct CoreFileTransferManifestEvent: Equatable, Sendable {
    public let sessionEpoch: UInt64
    public let requestID: Int32
    public let status: CoreFileTransferListStatus
    public let part: CoreFileTransferManifestPartKind
    public let entries: [CoreFileTransferListEntry]

    init?(
        sessionEpoch: UInt64, requestID: Int32, status: CoreFileTransferListStatus,
        part: CoreFileTransferManifestPartKind, entries: [CoreFileTransferListEntry]
    ) {
        guard sessionEpoch > 0, requestID > 0 else { return nil }
        if status != .success { guard entries.isEmpty else { return nil } }
        guard entries.count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES) else { return nil }

        var metadataBytes = 0
        var collisionKeys = Set<String>()
        for entry in entries {
            let nextMetadata = metadataBytes.addingReportingOverflow(entry.relativePath.utf8.count)
            guard !nextMetadata.overflow,
                nextMetadata.partialValue <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                ViewerFileTransferManifest.accepts(relativePath: entry.relativePath),
                !entry.relativePath.contains("\\"),
                entry.relativePath.rangeOfCharacter(from: .controlCharacters) == nil
            else { return nil }
            switch part {
            case .files:
                guard entry.kind == .file, Int64(exactly: entry.modifiedTime) != nil else {
                    return nil
                }
            case .emptyDirectories:
                guard entry.kind == .directory, entry.size == 0, entry.modifiedTime == 0 else {
                    return nil
                }
            }
            let collisionKey = entry.relativePath.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard collisionKeys.insert(collisionKey).inserted else { return nil }
            metadataBytes = nextMetadata.partialValue
        }
        self.sessionEpoch = sessionEpoch
        self.requestID = requestID
        self.status = status
        self.part = part
        self.entries = entries
    }

    package var recursiveManifestPart: ViewerFileTransferRecursiveManifestPart? {
        guard status == .success else { return nil }
        switch part {
        case .files:
            let files = entries.compactMap { entry in
                Int64(exactly: entry.modifiedTime).flatMap { modifiedTime in
                    ViewerFileTransferFile(
                        relativePath: entry.relativePath, size: entry.size,
                        modifiedTime: modifiedTime)
                }
            }
            guard files.count == entries.count else { return nil }
            return .files(files)
        case .emptyDirectories: return .emptyDirectories(entries.map(\.relativePath))
        }
    }
}

/// Path-free scalar projection used to register one Viewer download against
/// the exact recursive manifest that authorized it. Destination ownership
/// stays in Swift and never crosses the Viewer ABI at this lifecycle stage.
package struct CoreFileTransferDownloadStart: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let manifestRequestID: Int32
    package let transferID: Int32
    package let totalFiles: UInt32
    package let totalBytes: UInt64

    package init?(request: ViewerFileTransferDownloadRequest, manifestRequestID: Int32) {
        guard manifestRequestID > 0, let totalFiles = UInt32(exactly: request.manifest.files.count)
        else { return nil }
        sessionEpoch = request.sessionEpoch
        self.manifestRequestID = manifestRequestID
        transferID = request.transferID
        self.totalFiles = totalFiles
        totalBytes = request.manifest.totalBytes
    }
}
