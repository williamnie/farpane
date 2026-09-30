import CoreBridge
import Foundation
import VideoPipeline

/// 每秒采样与连接事件写入独立队列，失败时只关闭日志，不影响远控。
final class ViewerSessionLiveLog: @unchecked Sendable {
    enum Event: String {
        case sessionStarted
        case periodic
        case coreStateChanged
        case connectionStartFailed
        case reconnectAttempt
        case reconnectUnavailable
        case reconnectStarted
        case reconnectFailed
        case reconnectExhausted
        case sessionStopped
    }

    private struct Record: Encodable {
        let schema = "farpane-viewer-session"
        let schemaVersion = 1
        let sequence: UInt64
        let capturedAt: Date
        let monotonicNanoseconds: UInt64
        let sessionStartedAt: Date
        let buildIdentifier: String
        let event: String
        let forceRelay: Bool
        let coreGeneration: UInt64
        let coreState: String
        let stateCode: Int32
        let pipeline: ViewerPipelineDiagnosticSnapshot
    }

    static var defaultDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Logs/FarPane/ViewerSession", isDirectory: true)
    }

    private let queue = DispatchQueue(label: "farpane.viewer-session-log", qos: .utility)
    private let directory: URL
    private let maximumRecordsPerFile: Int
    private let startedAt = Date()
    private let forceRelay: Bool
    private let buildIdentifier =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable"
    private var handle: FileHandle?
    private var recordsInFile = 0
    private var sequence: UInt64 = 0
    private var coreState = "idle"
    private var stateCode: Int32 = 0
    private var finished = false

    init(directory: URL = defaultDirectoryURL, forceRelay: Bool, maximumRecordsPerFile: Int = 3_600)
        throws
    {
        guard maximumRecordsPerFile > 0 else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        self.directory = directory
        self.forceRelay = forceRelay
        self.maximumRecordsPerFile = maximumRecordsPerFile
        handle = try Self.openLog(in: directory)
    }

    deinit { try? handle?.close() }

    func record(
        _ event: Event, metrics: PipelineMetrics, coreGeneration: UInt64,
        state: CoreConnectionState? = nil, code: Int32 = 0
    ) {
        let snapshot = metrics.viewerDiagnosticSnapshot()
        let capturedAt = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        queue.async { [self] in
            guard !finished else { return }
            if let state {
                coreState = String(describing: state)
                stateCode = code
            }
            append(
                event, snapshot: snapshot, coreGeneration: coreGeneration, capturedAt: capturedAt,
                uptime: uptime)
        }
    }

    func finish(metrics: PipelineMetrics, coreGeneration: UInt64) {
        let snapshot = metrics.viewerDiagnosticSnapshot()
        let capturedAt = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds
        queue.sync {
            guard !finished else { return }
            append(
                .sessionStopped, snapshot: snapshot, coreGeneration: coreGeneration,
                capturedAt: capturedAt, uptime: uptime)
            finished = true
            try? handle?.close()
            handle = nil
        }
    }

    private func append(
        _ event: Event, snapshot: ViewerPipelineDiagnosticSnapshot, coreGeneration: UInt64,
        capturedAt: Date, uptime: UInt64
    ) {
        guard handle != nil else { return }
        do {
            if recordsInFile >= maximumRecordsPerFile {
                try handle?.close()
                handle = try Self.openLog(in: directory)
                recordsInFile = 0
            }
            let record = Record(
                sequence: sequence + 1, capturedAt: capturedAt, monotonicNanoseconds: uptime,
                sessionStartedAt: startedAt, buildIdentifier: buildIdentifier,
                event: event.rawValue, forceRelay: forceRelay, coreGeneration: coreGeneration,
                coreState: coreState, stateCode: stateCode, pipeline: snapshot)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(record)
            data.append(0x0A)
            try handle?.write(contentsOf: data)
            sequence += 1
            recordsInFile += 1
        } catch {
            try? handle?.close()
            handle = nil
            fputs("Viewer session log unavailable.\n", stderr)
        }
    }

    private static func openLog(in directory: URL) throws -> FileHandle {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var candidates: [(url: URL, modified: Date)] = []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "jsonl", name.hasPrefix("viewer-session-"),
                UUID(uuidString: String(name.suffix(36))) != nil
            else { continue }
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
                (attributes[.referenceCount] as? NSNumber)?.intValue == 1
            else { continue }
            candidates.append((file, attributes[.modificationDate] as? Date ?? .distantPast))
        }
        candidates.sort { $0.modified > $1.modified }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for (index, file) in candidates.enumerated() where index >= 23 || file.modified < cutoff {
            // unlink 只移除该目录项，路径被替换为目录时也不会递归删除。
            let result = file.url.withUnsafeFileSystemRepresentation { path in
                path.map { unlink($0) } ?? -1
            }
            guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
            of: ":", with: "")
        let url = directory.appendingPathComponent(
            "viewer-session-\(timestamp)-\(UUID().uuidString).jsonl")
        try Data().write(to: url, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try FileHandle(forWritingTo: url)
    }
}
