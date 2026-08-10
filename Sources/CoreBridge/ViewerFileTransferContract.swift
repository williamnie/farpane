import Foundation

package enum ViewerFileTransferDirection: UInt32, Equatable, Sendable {
    case download = 1
}

package enum ViewerFileTransferFailure: UInt32, Equatable, Sendable {
    case rejected = 1
    case unavailable = 2
    case protocolViolation = 3
    case localIO = 4
    case connectionClosed = 5
}

package struct ViewerFileTransferDestinationLease: Equatable, Sendable {
    package let token: UInt64
    package let sessionEpoch: UInt64

    package init?(token: UInt64, sessionEpoch: UInt64) {
        guard token > 0, sessionEpoch > 0 else { return nil }
        self.token = token
        self.sessionEpoch = sessionEpoch
    }
}

package struct ViewerFileTransferFile: Equatable, Sendable {
    package let relativePath: String
    package let size: UInt64
    package let modifiedTime: Int64

    package init?(relativePath: String, size: UInt64, modifiedTime: Int64) {
        guard ViewerFileTransferManifest.accepts(relativePath: relativePath) else {
            return nil
        }
        self.relativePath = relativePath
        self.size = size
        self.modifiedTime = modifiedTime
    }
}

package struct ViewerFileTransferManifest: Equatable, Sendable {
    package static let maximumEntries = 1_024
    package static let maximumMetadataUTF8Bytes = 1_024 * 1_024
    package static let privateStagingSuffix = ".farpane-part"

    package let files: [ViewerFileTransferFile]
    package let emptyDirectories: [String]
    package let totalBytes: UInt64
    package let metadataUTF8Bytes: Int

    package init?(files: [ViewerFileTransferFile], emptyDirectories: [String]) {
        let entryCount = files.count.addingReportingOverflow(emptyDirectories.count)
        guard
            !entryCount.overflow,
            entryCount.partialValue > 0,
            entryCount.partialValue <= Self.maximumEntries,
            emptyDirectories.allSatisfy(Self.accepts(relativePath:))
        else { return nil }

        let paths = files.map(\.relativePath) + emptyDirectories
        let canonicalPaths = paths.map(Self.canonicalCollisionKey)
        let canonicalPathSet = Set(canonicalPaths)
        guard canonicalPathSet.count == paths.count else { return nil }

        for path in canonicalPaths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count > 1 else { continue }
            var ancestor = ""
            for component in components.dropLast() {
                ancestor = ancestor.isEmpty ? String(component) : ancestor + "/" + component
                if canonicalPathSet.contains(ancestor) { return nil }
            }
        }

        var totalBytes: UInt64 = 0
        var metadataBytes = 0
        for path in paths {
            let nextMetadata = metadataBytes.addingReportingOverflow(path.utf8.count)
            guard
                !nextMetadata.overflow,
                nextMetadata.partialValue <= Self.maximumMetadataUTF8Bytes
            else { return nil }
            metadataBytes = nextMetadata.partialValue
        }
        for file in files {
            let nextTotal = totalBytes.addingReportingOverflow(file.size)
            guard !nextTotal.overflow else { return nil }
            totalBytes = nextTotal.partialValue
        }

        self.files = files
        self.emptyDirectories = emptyDirectories
        self.totalBytes = totalBytes
        metadataUTF8Bytes = metadataBytes
    }

    package static func accepts(relativePath: String) -> Bool {
        guard
            !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.hasSuffix("/"),
            !relativePath.contains("\0"),
            relativePath.utf8.count <= maximumMetadataUTF8Bytes,
            relativePath.utf8.elementsEqual(
                relativePath.precomposedStringWithCanonicalMapping.utf8
            )
        else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { component in
            component != "."
                && component != ".."
                && !component.isEmpty
                && !component.lowercased().hasSuffix(privateStagingSuffix)
        }
    }

    private static func canonicalCollisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}

package struct ViewerFileTransferDownloadRequest: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let transferID: Int32
    package let destination: ViewerFileTransferDestinationLease
    package let manifest: ViewerFileTransferManifest

    package init?(
        sessionEpoch: UInt64,
        transferID: Int32,
        destination: ViewerFileTransferDestinationLease,
        manifest: ViewerFileTransferManifest
    ) {
        guard
            sessionEpoch > 0,
            transferID > 0,
            destination.sessionEpoch == sessionEpoch
        else { return nil }
        self.sessionEpoch = sessionEpoch
        self.transferID = transferID
        self.destination = destination
        self.manifest = manifest
    }
}

package enum ViewerFileTransferProgressPhase: Equatable, Sendable {
    case queued
    case transferring
    case waitingForConflict
    case cancelling
    case completed
    case cancelled
    case failed(ViewerFileTransferFailure)

    package var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            return true
        case .queued, .transferring, .waitingForConflict, .cancelling:
            return false
        }
    }
}

package struct ViewerFileTransferProgressUpdate: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let transferID: Int32
    package let sequence: UInt64
    package let phase: ViewerFileTransferProgressPhase
    package let currentFileNumber: Int?
    package let filesCompleted: Int
    package let bytesCompleted: UInt64
    package let bytesPerSecond: Double

    package init(
        sessionEpoch: UInt64,
        transferID: Int32,
        sequence: UInt64,
        phase: ViewerFileTransferProgressPhase,
        currentFileNumber: Int?,
        filesCompleted: Int,
        bytesCompleted: UInt64,
        bytesPerSecond: Double
    ) {
        self.sessionEpoch = sessionEpoch
        self.transferID = transferID
        self.sequence = sequence
        self.phase = phase
        self.currentFileNumber = currentFileNumber
        self.filesCompleted = filesCompleted
        self.bytesCompleted = bytesCompleted
        self.bytesPerSecond = bytesPerSecond
    }
}

extension CoreFileTransferEvent {
    package var viewerProgressUpdate: ViewerFileTransferProgressUpdate? {
        let phase: ViewerFileTransferProgressPhase
        switch kind {
        case .progress:
            phase = .transferring
        case .waitingForConflict:
            phase = .waitingForConflict
        case .completed:
            phase = .completed
        case .cancelled:
            phase = .cancelled
        case .failed:
            guard let stableFailure = failure.viewerFailure else { return nil }
            phase = .failed(stableFailure)
        }

        return ViewerFileTransferProgressUpdate(
            sessionEpoch: sessionEpoch,
            transferID: transferID,
            sequence: sequence,
            phase: phase,
            currentFileNumber: currentFileNumber,
            filesCompleted: Int(filesCompleted),
            bytesCompleted: bytesCompleted,
            bytesPerSecond: bytesPerSecond
        )
    }
}

private extension CoreFileTransferFailure {
    var viewerFailure: ViewerFileTransferFailure? {
        switch self {
        case .none:
            nil
        case .rejected:
            .rejected
        case .unavailable:
            .unavailable
        case .protocolViolation:
            .protocolViolation
        case .localIO:
            .localIO
        case .connectionClosed:
            .connectionClosed
        }
    }
}

package struct ViewerFileTransferProgressSnapshot: Equatable, Sendable {
    package let sessionEpoch: UInt64
    package let transferID: Int32
    package let direction: ViewerFileTransferDirection
    package let sequence: UInt64
    package let phase: ViewerFileTransferProgressPhase
    package let currentFileNumber: Int?
    package let filesCompleted: Int
    package let totalFiles: Int
    package let bytesCompleted: UInt64
    package let totalBytes: UInt64
    package let bytesPerSecond: Double
}

/// Pure Viewer contract for a future file-transfer adapter. Local paths and
/// descriptors stay behind the destination lease owner; callbacks expose only
/// bounded manifest metadata, monotonic progress and stable failure kinds.
package struct ViewerFileTransferProgressAuthority: Sendable {
    package static let maximumConcurrentTransfers = 8

    private struct ActiveTransfer: Sendable {
        let request: ViewerFileTransferDownloadRequest
        var snapshot: ViewerFileTransferProgressSnapshot
    }

    private var activeTransfers: [Int32: ActiveTransfer] = [:]

    package init() {}

    package var activeCount: Int { activeTransfers.count }

    package mutating func begin(
        _ request: ViewerFileTransferDownloadRequest
    ) -> ViewerFileTransferProgressSnapshot? {
        guard
            activeTransfers.count < Self.maximumConcurrentTransfers,
            activeTransfers[request.transferID] == nil
        else { return nil }
        let snapshot = ViewerFileTransferProgressSnapshot(
            sessionEpoch: request.sessionEpoch,
            transferID: request.transferID,
            direction: .download,
            sequence: 0,
            phase: .queued,
            currentFileNumber: nil,
            filesCompleted: 0,
            totalFiles: request.manifest.files.count,
            bytesCompleted: 0,
            totalBytes: request.manifest.totalBytes,
            bytesPerSecond: 0
        )
        activeTransfers[request.transferID] = ActiveTransfer(
            request: request,
            snapshot: snapshot
        )
        return snapshot
    }

    package mutating func observe(
        _ update: ViewerFileTransferProgressUpdate
    ) -> ViewerFileTransferProgressSnapshot? {
        guard var active = activeTransfers[update.transferID] else { return nil }
        let previous = active.snapshot
        guard
            update.sessionEpoch == previous.sessionEpoch,
            update.sequence > previous.sequence,
            update.filesCompleted >= previous.filesCompleted,
            update.filesCompleted <= previous.totalFiles,
            update.bytesCompleted >= previous.bytesCompleted,
            update.bytesCompleted <= previous.totalBytes,
            update.bytesPerSecond.isFinite,
            update.bytesPerSecond >= 0,
            acceptsTransition(from: previous.phase, to: update.phase),
            acceptsFileNumber(update.currentFileNumber, totalFiles: previous.totalFiles)
        else { return nil }

        if update.phase == .waitingForConflict, update.currentFileNumber == nil {
            return nil
        }
        if update.phase.isTerminal, update.currentFileNumber != nil {
            return nil
        }
        if update.phase == .completed,
           (update.filesCompleted != previous.totalFiles
               || update.bytesCompleted != previous.totalBytes) {
            return nil
        }

        let snapshot = ViewerFileTransferProgressSnapshot(
            sessionEpoch: previous.sessionEpoch,
            transferID: previous.transferID,
            direction: previous.direction,
            sequence: update.sequence,
            phase: update.phase,
            currentFileNumber: update.currentFileNumber,
            filesCompleted: update.filesCompleted,
            totalFiles: previous.totalFiles,
            bytesCompleted: update.bytesCompleted,
            totalBytes: previous.totalBytes,
            bytesPerSecond: update.bytesPerSecond
        )
        if snapshot.phase.isTerminal {
            activeTransfers.removeValue(forKey: update.transferID)
        } else {
            active.snapshot = snapshot
            activeTransfers[update.transferID] = active
        }
        return snapshot
    }

    package mutating func requestCancellation(
        sessionEpoch: UInt64,
        transferID: Int32
    ) -> ViewerFileTransferProgressSnapshot? {
        guard var active = activeTransfers[transferID] else { return nil }
        let previous = active.snapshot
        guard
            previous.sessionEpoch == sessionEpoch,
            !previous.phase.isTerminal,
            previous.phase != .cancelling
        else { return nil }
        let snapshot = ViewerFileTransferProgressSnapshot(
            sessionEpoch: previous.sessionEpoch,
            transferID: previous.transferID,
            direction: previous.direction,
            sequence: previous.sequence,
            phase: .cancelling,
            currentFileNumber: previous.currentFileNumber,
            filesCompleted: previous.filesCompleted,
            totalFiles: previous.totalFiles,
            bytesCompleted: previous.bytesCompleted,
            totalBytes: previous.totalBytes,
            bytesPerSecond: 0
        )
        active.snapshot = snapshot
        activeTransfers[transferID] = active
        return snapshot
    }

    package mutating func teardown(sessionEpoch: UInt64) -> [Int32] {
        let identifiers = activeTransfers.values.compactMap { active in
            active.snapshot.sessionEpoch == sessionEpoch ? active.snapshot.transferID : nil
        }.sorted()
        for identifier in identifiers {
            activeTransfers.removeValue(forKey: identifier)
        }
        return identifiers
    }

    private func acceptsTransition(
        from: ViewerFileTransferProgressPhase,
        to: ViewerFileTransferProgressPhase
    ) -> Bool {
        switch from {
        case .queued:
            return to == .transferring
                || to == .waitingForConflict
                || to == .completed
                || to == .cancelled
                || isFailure(to)
        case .transferring, .waitingForConflict:
            return to == .transferring
                || to == .waitingForConflict
                || to == .completed
                || to == .cancelled
                || isFailure(to)
        case .cancelling:
            return to == .completed || to == .cancelled || isFailure(to)
        case .completed, .cancelled, .failed:
            return false
        }
    }

    private func acceptsFileNumber(_ value: Int?, totalFiles: Int) -> Bool {
        guard let value else { return true }
        return value >= 0 && value < totalFiles
    }

    private func isFailure(_ phase: ViewerFileTransferProgressPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }
}
