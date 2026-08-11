import CoreBridgeShim
import Foundation

public enum CoreBridgeError: Error, CustomStringConvertible {
    case load(String)
    case createClient
    case connect(Int32)
    case invalidUpstreamCommit(String)

    public var description: String {
        switch self {
        case .load(let message): return "Rust core load failed: \(message)"
        case .createClient: return "Rust core client creation failed"
        case .connect(let code): return "Rust core connection start failed: \(code)"
        case .invalidUpstreamCommit(let commit): return "unexpected RustDesk core commit: \(commit)"
        }
    }
}

public enum CoreConnectionState: Int32, Codable, Sendable {
    case idle = 0
    case connecting = 1
    case transportReady = 2
    case authenticated = 3
    case streaming = 4
    case passwordRequired = 5
    case authenticationFailed = 6
    case disconnected = 7
    case error = 8
    case controlReady = 9
}

public enum CoreVideoCodec: Int32, Codable, Sendable {
    case unknown = 0
    case h264 = 1
    case h265 = 2
}

public enum CorePacketFormat: Int32, Codable, Sendable {
    case unknown = 0
    case annexB = 1
    case avcc = 2
    case mixed = 3
}

public struct CoreStateEvent: Sendable {
    public let state: CoreConnectionState
    public let code: Int32
    public let message: String
}

public struct CoreVideoPacket: Sendable {
    public let codec: CoreVideoCodec
    public let format: CorePacketFormat
    public let data: Data
    public let sequence: UInt64
    public let timestampUS: UInt64
    public let flags: UInt32
    public let width: UInt32
    public let height: UInt32
    public let display: UInt32
    public let connectionEpoch: UInt64
    public let displayCatalogRevision: UInt64

    public var isKeyframe: Bool { flags & UInt32(RDN_VIDEO_FLAG_KEYFRAME.rawValue) != 0 }
    public var containsVPS: Bool { flags & UInt32(RDN_VIDEO_FLAG_VPS.rawValue) != 0 }
    public var containsSPS: Bool { flags & UInt32(RDN_VIDEO_FLAG_SPS.rawValue) != 0 }
    public var containsPPS: Bool { flags & UInt32(RDN_VIDEO_FLAG_PPS.rawValue) != 0 }
}

public enum CoreDisplayCatalogStatus: UInt32, Equatable, Sendable {
    case available = 1
    case unavailable = 2
}

public struct CoreDisplayCatalogEntry: Equatable, Sendable {
    public let displayIndex: UInt32
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32
    public let online: Bool
    public let scale: Double
    public let name: String

    public init?(
        displayIndex: UInt32,
        x: Int32,
        y: Int32,
        width: Int32,
        height: Int32,
        online: Bool,
        scale: Double,
        name: String
    ) {
        let validGeometry = online ? (width > 0 && height > 0) : (width >= 0 && height >= 0)
        guard
            validGeometry,
            scale.isFinite,
            scale > 0,
            scale <= 16,
            name.utf8.count <= Int(RDN_MAX_DISPLAY_NAME_UTF8_BYTES),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        self.displayIndex = displayIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.online = online
        self.scale = scale
        self.name = name
    }
}

public struct CoreDisplayCatalogEvent: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let catalogRevision: UInt64
    public let status: CoreDisplayCatalogStatus
    public let selectedDisplayIndex: UInt32?
    public let entries: [CoreDisplayCatalogEntry]

    public init?(
        connectionEpoch: UInt64,
        catalogRevision: UInt64,
        status: CoreDisplayCatalogStatus,
        selectedDisplayIndex: UInt32?,
        entries: [CoreDisplayCatalogEntry]
    ) {
        guard connectionEpoch > 0, catalogRevision > 0,
              entries.count <= Int(RDN_MAX_DISPLAY_CATALOG_ENTRIES) else { return nil }
        switch status {
        case .available:
            guard entries.enumerated().allSatisfy({ offset, entry in
                entry.displayIndex == UInt32(offset)
            }) else { return nil }
            if let selectedDisplayIndex {
                guard entries.indices.contains(Int(selectedDisplayIndex)),
                      entries[Int(selectedDisplayIndex)].online else { return nil }
            }
        case .unavailable:
            guard entries.isEmpty, selectedDisplayIndex == nil else { return nil }
        }
        self.connectionEpoch = connectionEpoch
        self.catalogRevision = catalogRevision
        self.status = status
        self.selectedDisplayIndex = selectedDisplayIndex
        self.entries = entries
    }
}

public struct CoreDisplayCatalogProjectionState: Sendable {
    private var current: CoreDisplayCatalogEvent?
    private var deliveryEnabled = true

    public init() {}

    @discardableResult
    public mutating func observe(_ event: CoreDisplayCatalogEvent) -> Bool {
        guard deliveryEnabled else { return false }
        if let current {
            guard event.connectionEpoch >= current.connectionEpoch else { return false }
            if event.connectionEpoch == current.connectionEpoch {
                guard event.catalogRevision >= current.catalogRevision else { return false }
                if event.catalogRevision == current.catalogRevision {
                    guard event.status == current.status, event.entries == current.entries else {
                        return false
                    }
                }
            }
        }
        current = event
        return true
    }

    public func acceptsFrame(
        connectionEpoch: UInt64,
        catalogRevision: UInt64,
        displayIndex: UInt32
    ) -> Bool {
        guard deliveryEnabled, let current, current.status == .available else { return false }
        return current.connectionEpoch == connectionEpoch
            && current.catalogRevision == catalogRevision
            && current.selectedDisplayIndex == displayIndex
    }

    func isCurrent(_ event: CoreDisplayCatalogEvent) -> Bool {
        deliveryEnabled && current == event
    }

    public mutating func stop() {
        deliveryEnabled = false
        current = nil
    }
}

public enum CoreDisplaySelectionResult: UInt32, Equatable, Sendable {
    case selected = 1
    case alreadySelected = 2
    case failed = 3
}

public enum CoreDisplaySelectionFailure: UInt32, Equatable, Sendable {
    case none = 0
    case catalogChanged = 1
    case connectionClosed = 2
    case remoteSelectionDrift = 3
}

public struct CoreDisplaySelectionRequest: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let commandID: UInt64
    public let catalogRevision: UInt64
    public let displayIndex: UInt32

    public init?(
        connectionEpoch: UInt64,
        commandID: UInt64,
        catalogRevision: UInt64,
        displayIndex: UInt32
    ) {
        guard connectionEpoch > 0, commandID > 0, catalogRevision > 0 else { return nil }
        self.connectionEpoch = connectionEpoch
        self.commandID = commandID
        self.catalogRevision = catalogRevision
        self.displayIndex = displayIndex
    }
}

public struct CoreDisplaySelectionEvent: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let commandID: UInt64
    public let catalogRevision: UInt64
    public let displayIndex: UInt32
    public let result: CoreDisplaySelectionResult
    public let failure: CoreDisplaySelectionFailure

    public init?(
        connectionEpoch: UInt64,
        commandID: UInt64,
        catalogRevision: UInt64,
        displayIndex: UInt32,
        result: CoreDisplaySelectionResult,
        failure: CoreDisplaySelectionFailure
    ) {
        guard connectionEpoch > 0, commandID > 0, catalogRevision > 0 else { return nil }
        switch result {
        case .selected, .alreadySelected:
            guard failure == .none else { return nil }
        case .failed:
            guard failure != .none else { return nil }
        }
        self.connectionEpoch = connectionEpoch
        self.commandID = commandID
        self.catalogRevision = catalogRevision
        self.displayIndex = displayIndex
        self.result = result
        self.failure = failure
    }
}

public struct CoreRuntimeMetrics: Sendable {
    public let remoteFPS: Double
    public let networkDelayMS: Int32
    public let targetBitrate: UInt64
}

public struct CoreClipboardRichTextPayload: Sendable, Equatable {
    public let plainText: String?
    public let rtf: String?
    public let html: String?

    public init(plainText: String? = nil, rtf: String? = nil, html: String? = nil) {
        self.plainText = plainText
        self.rtf = rtf
        self.html = html
    }
}

public enum CoreClipboardImagePayload: Sendable, Equatable {
    case rgba(width: UInt32, height: UInt32, pixels: Data)
    case png(Data)
    case svg(String)
}

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
        sessionEpoch: UInt64,
        transferID: Int32,
        sequence: UInt64,
        kind: CoreFileTransferEventKind,
        failure: CoreFileTransferFailure,
        currentFileNumber: Int?,
        filesCompleted: UInt32,
        totalFiles: UInt32,
        bytesCompleted: UInt64,
        totalBytes: UInt64,
        bytesPerSecond: Double
    ) {
        guard
            sessionEpoch > 0,
            transferID > 0,
            sequence > 0,
            filesCompleted <= totalFiles,
            bytesCompleted <= totalBytes,
            bytesPerSecond.isFinite,
            bytesPerSecond >= 0,
            currentFileNumber.map({ $0 >= 0 && $0 < Int(totalFiles) }) ?? true
        else { return nil }

        switch kind {
        case .progress:
            guard failure == .none else { return nil }
        case .waitingForConflict:
            guard failure == .none, currentFileNumber != nil else { return nil }
        case .completed:
            guard
                failure == .none,
                currentFileNumber == nil,
                filesCompleted == totalFiles,
                bytesCompleted == totalBytes
            else { return nil }
        case .cancelled:
            guard failure == .none, currentFileNumber == nil else { return nil }
        case .failed:
            guard failure != .none, currentFileNumber == nil else { return nil }
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

    init?(
        sessionEpoch: UInt64,
        transferID: Int32,
        fileNumber: UInt32,
        payload: Data
    ) {
        guard
            sessionEpoch > 0,
            transferID > 0,
            Int(fileNumber) < Self.maximumFileCount,
            !payload.isEmpty,
            payload.count <= Self.maximumPayloadBytes
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

    init(kind: CoreFileTransferListEntryKind, relativePath: String, size: UInt64, modifiedTime: UInt64) {
        self.kind = kind
        self.relativePath = relativePath
        self.size = size
        self.modifiedTime = modifiedTime
    }
}

public struct CoreFileTransferListEvent: Equatable, Sendable {
    public let sessionEpoch: UInt64
    public let requestID: Int32
    public let status: CoreFileTransferListStatus
    public let entries: [CoreFileTransferListEntry]

    init?(
        sessionEpoch: UInt64,
        requestID: Int32,
        status: CoreFileTransferListStatus,
        entries: [CoreFileTransferListEntry]
    ) {
        guard sessionEpoch > 0, requestID > 0 else { return nil }
        if status != .success {
            guard entries.isEmpty else { return nil }
        }
        guard entries.count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES) else { return nil }

        var metadataBytes = 0
        var collisionKeys = Set<String>()
        for entry in entries {
            let nextMetadata = metadataBytes.addingReportingOverflow(entry.relativePath.utf8.count)
            guard
                !nextMetadata.overflow,
                nextMetadata.partialValue <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                ViewerFileTransferManifest.accepts(relativePath: entry.relativePath),
                !entry.relativePath.contains("/"),
                !entry.relativePath.contains("\\"),
                entry.relativePath.rangeOfCharacter(from: .controlCharacters) == nil,
                entry.kind != .directory || entry.size == 0
            else { return nil }
            let collisionKey = entry.relativePath.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
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
        sessionEpoch: UInt64,
        requestID: Int32,
        status: CoreFileTransferListStatus,
        part: CoreFileTransferManifestPartKind,
        entries: [CoreFileTransferListEntry]
    ) {
        guard sessionEpoch > 0, requestID > 0 else { return nil }
        if status != .success {
            guard entries.isEmpty else { return nil }
        }
        guard entries.count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES) else {
            return nil
        }

        var metadataBytes = 0
        var collisionKeys = Set<String>()
        for entry in entries {
            let nextMetadata = metadataBytes.addingReportingOverflow(
                entry.relativePath.utf8.count
            )
            guard
                !nextMetadata.overflow,
                nextMetadata.partialValue
                    <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                ViewerFileTransferManifest.accepts(relativePath: entry.relativePath),
                !entry.relativePath.contains("\\"),
                entry.relativePath.rangeOfCharacter(from: .controlCharacters) == nil
            else { return nil }
            switch part {
            case .files:
                guard
                    entry.kind == .file,
                    Int64(exactly: entry.modifiedTime) != nil
                else { return nil }
            case .emptyDirectories:
                guard
                    entry.kind == .directory,
                    entry.size == 0,
                    entry.modifiedTime == 0
                else { return nil }
            }
            let collisionKey = entry.relativePath.precomposedStringWithCanonicalMapping.folding(
                options: [.caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
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
                        relativePath: entry.relativePath,
                        size: entry.size,
                        modifiedTime: modifiedTime
                    )
                }
            }
            guard files.count == entries.count else { return nil }
            return .files(files)
        case .emptyDirectories:
            return .emptyDirectories(entries.map(\.relativePath))
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

    package init?(
        request: ViewerFileTransferDownloadRequest,
        manifestRequestID: Int32
    ) {
        guard
            manifestRequestID > 0,
            let totalFiles = UInt32(exactly: request.manifest.files.count)
        else { return nil }
        sessionEpoch = request.sessionEpoch
        self.manifestRequestID = manifestRequestID
        transferID = request.transferID
        self.totalFiles = totalFiles
        totalBytes = request.manifest.totalBytes
    }
}

public struct CoreConnectionConfig: Sendable {
    public let rendezvousServer: String
    public let serverPublicKey: String
    public let peerID: String
    public let password: String
    public let forceRelay: Bool
    public let receiveAudio: Bool
    public let receiveClipboardText: Bool
    public let sendClipboardText: Bool
    public let receiveClipboardRichText: Bool
    public let sendClipboardRichText: Bool
    public let receiveClipboardImage: Bool
    public let sendClipboardImage: Bool
    public let fileTransferEnabled: Bool
    public let fileTransferSessionEpoch: UInt64

    public init(
        rendezvousServer: String,
        serverPublicKey: String,
        peerID: String,
        password: String = "",
        forceRelay: Bool = false,
        receiveAudio: Bool = false,
        receiveClipboardText: Bool = false,
        sendClipboardText: Bool = false,
        receiveClipboardRichText: Bool = false,
        sendClipboardRichText: Bool = false,
        receiveClipboardImage: Bool = false,
        sendClipboardImage: Bool = false,
        fileTransferEnabled: Bool = false,
        fileTransferSessionEpoch: UInt64 = 0
    ) {
        self.rendezvousServer = rendezvousServer
        self.serverPublicKey = serverPublicKey
        self.peerID = peerID
        self.password = password
        self.forceRelay = forceRelay
        self.receiveAudio = receiveAudio
        self.receiveClipboardText = receiveClipboardText
        self.sendClipboardText = sendClipboardText
        self.receiveClipboardRichText = receiveClipboardRichText
        self.sendClipboardRichText = sendClipboardRichText
        self.receiveClipboardImage = receiveClipboardImage
        self.sendClipboardImage = sendClipboardImage
        self.fileTransferEnabled = fileTransferEnabled
        self.fileTransferSessionEpoch = fileTransferSessionEpoch
    }
}

public struct CoreInputModifiers: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let shift = Self(rawValue: 1 << 0)
    public static let control = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let command = Self(rawValue: 1 << 3)
}

public enum CorePointerKind: UInt32, Sendable {
    case move = 0
    case down = 1
    case up = 2
    case scroll = 3
    case preciseScroll = 4
}

public struct CorePointerButtons: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let left = Self(rawValue: 1 << 0)
    public static let right = Self(rawValue: 1 << 1)
    public static let middle = Self(rawValue: 1 << 2)
}

public struct CorePointerEvent: Sendable {
    public let kind: CorePointerKind
    public let x: Int32
    public let y: Int32
    public let scrollX: Int32
    public let scrollY: Int32
    public let buttons: CorePointerButtons
    public let modifiers: CoreInputModifiers

    public init(
        kind: CorePointerKind,
        x: Int32 = 0,
        y: Int32 = 0,
        scrollX: Int32 = 0,
        scrollY: Int32 = 0,
        buttons: CorePointerButtons = [],
        modifiers: CoreInputModifiers = []
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.buttons = buttons
        self.modifiers = modifiers
    }
}

public enum CoreSpecialKey: UInt32, Sendable {
    case escape = 1
    case `return` = 2
    case tab = 3
    case backspace = 4
    case deleteForward = 5
    case left = 6
    case right = 7
    case up = 8
    case down = 9
    case space = 10
    case shift = 11
    case control = 12
    case option = 13
    case command = 14
    case home = 15
    case end = 16
    case pageUp = 17
    case pageDown = 18
}

public enum CoreKey: Sendable, Equatable {
    case character(Unicode.Scalar)
    case special(CoreSpecialKey)
    /// A macOS hardware key position handled by RustDesk Core's map mode.
    case physical(UInt16)
}

public struct CoreKeyEvent: Sendable {
    public let key: CoreKey
    public let isDown: Bool
    public let modifiers: CoreInputModifiers

    public init(key: CoreKey, isDown: Bool, modifiers: CoreInputModifiers = []) {
        self.key = key
        self.isDown = isDown
        self.modifiers = modifiers
    }
}

private final class FileTransferCancelRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (library: OpaquePointer, client: OpaquePointer)?

    func bind(library: OpaquePointer, client: OpaquePointer) {
        lock.withLock {
            precondition(target == nil)
            target = (library, client)
        }
    }

    @discardableResult
    func cancel(sessionEpoch: UInt64, transferID: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let target else { return nil }
        return rdn_shim_client_file_transfer_cancel(
            target.library,
            target.client,
            sessionEpoch,
            transferID
        )
    }

    func unbind() {
        lock.withLock { target = nil }
    }
}

private final class CallbackBox: @unchecked Sendable {
    let queue: DispatchQueue
    let onState: @Sendable (CoreStateEvent) -> Void
    let onVideo: @Sendable (CoreVideoPacket) -> Void
    let onDisplayCatalog: @Sendable (CoreDisplayCatalogEvent) -> Void
    let onDisplaySelection: @Sendable (CoreDisplaySelectionEvent) -> Void
    let onMetrics: @Sendable (CoreRuntimeMetrics) -> Void
    let onClipboardText: @Sendable (String) -> Void
    let onClipboardRichText: @Sendable (CoreClipboardRichTextPayload) -> Void
    let onClipboardImage: @Sendable (CoreClipboardImagePayload) -> Void
    let onFileTransferEvent: @Sendable (CoreFileTransferEvent) -> Void
    let onFileTransferList: @Sendable (CoreFileTransferListEvent) -> Void
    let onFileTransferManifest: @Sendable (CoreFileTransferManifestEvent) -> Void
    let onFileTransferReceiveBlock: @Sendable (CoreFileTransferReceiveBlock) -> Void
    private let fileTransferCancelRelay: FileTransferCancelRelay
    private let fileTransferReceiveAdapter: ViewerFileTransferReceiveAdapter
    private let fileTransferUploadReadAdapter: ViewerFileTransferUploadReadAdapter
    private let clipboardLifecycleLock = NSLock()
    private var clipboardDeliveryEnabled = true
    private let fileTransferLifecycleLock = NSLock()
    private var fileTransferDeliveryEnabled = true
    private let displayLifecycleLock = NSLock()
    private var displayProjection = CoreDisplayCatalogProjectionState()

    init(
        queue: DispatchQueue,
        onState: @escaping @Sendable (CoreStateEvent) -> Void,
        onVideo: @escaping @Sendable (CoreVideoPacket) -> Void,
        onDisplayCatalog: @escaping @Sendable (CoreDisplayCatalogEvent) -> Void,
        onDisplaySelection: @escaping @Sendable (CoreDisplaySelectionEvent) -> Void,
        onMetrics: @escaping @Sendable (CoreRuntimeMetrics) -> Void,
        onClipboardText: @escaping @Sendable (String) -> Void,
        onClipboardRichText: @escaping @Sendable (CoreClipboardRichTextPayload) -> Void,
        onClipboardImage: @escaping @Sendable (CoreClipboardImagePayload) -> Void,
        onFileTransferEvent: @escaping @Sendable (CoreFileTransferEvent) -> Void,
        onFileTransferList: @escaping @Sendable (CoreFileTransferListEvent) -> Void,
        onFileTransferManifest: @escaping @Sendable (CoreFileTransferManifestEvent) -> Void,
        onFileTransferReceiveBlock: @escaping @Sendable (CoreFileTransferReceiveBlock) -> Void,
        fileTransferCancelRelay: FileTransferCancelRelay,
        fileTransferReceiveAdapter: ViewerFileTransferReceiveAdapter,
        fileTransferUploadReadAdapter: ViewerFileTransferUploadReadAdapter
    ) {
        self.queue = queue
        self.onState = onState
        self.onVideo = onVideo
        self.onDisplayCatalog = onDisplayCatalog
        self.onDisplaySelection = onDisplaySelection
        self.onMetrics = onMetrics
        self.onClipboardText = onClipboardText
        self.onClipboardRichText = onClipboardRichText
        self.onClipboardImage = onClipboardImage
        self.onFileTransferEvent = onFileTransferEvent
        self.onFileTransferList = onFileTransferList
        self.onFileTransferManifest = onFileTransferManifest
        self.onFileTransferReceiveBlock = onFileTransferReceiveBlock
        self.fileTransferCancelRelay = fileTransferCancelRelay
        self.fileTransferReceiveAdapter = fileTransferReceiveAdapter
        self.fileTransferUploadReadAdapter = fileTransferUploadReadAdapter
    }

    func observeDisplayCatalog(_ event: CoreDisplayCatalogEvent) {
        guard displayLifecycleLock.withLock({ displayProjection.observe(event) }) else { return }
        queue.async { [self] in
            guard displayLifecycleLock.withLock({ displayProjection.isCurrent(event) }) else { return }
            onDisplayCatalog(event)
        }
    }

    func deliverDisplaySelection(_ event: CoreDisplaySelectionEvent) {
        queue.async { [self] in onDisplaySelection(event) }
    }

    func acceptsVideoFrame(connectionEpoch: UInt64, catalogRevision: UInt64, displayIndex: UInt32) -> Bool {
        displayLifecycleLock.withLock {
            displayProjection.acceptsFrame(
                connectionEpoch: connectionEpoch,
                catalogRevision: catalogRevision,
                displayIndex: displayIndex
            )
        }
    }

    func deliverVideo(_ packet: CoreVideoPacket) {
        queue.async { [self] in
            guard acceptsVideoFrame(
                connectionEpoch: packet.connectionEpoch,
                catalogRevision: packet.displayCatalogRevision,
                displayIndex: packet.display
            ) else { return }
            onVideo(packet)
        }
    }

    func stopDisplayDelivery() {
        displayLifecycleLock.withLock { displayProjection.stop() }
    }

    func deliverClipboardText(_ text: String) {
        queue.async { [self] in
            guard clipboardLifecycleLock.withLock({ clipboardDeliveryEnabled }) else { return }
            onClipboardText(text)
        }
    }

    func deliverClipboardRichText(_ payload: CoreClipboardRichTextPayload) {
        queue.async { [self] in
            guard clipboardLifecycleLock.withLock({ clipboardDeliveryEnabled }) else { return }
            onClipboardRichText(payload)
        }
    }

    func deliverClipboardImage(_ payload: CoreClipboardImagePayload) {
        queue.async { [self] in
            guard clipboardLifecycleLock.withLock({ clipboardDeliveryEnabled }) else { return }
            onClipboardImage(payload)
        }
    }

    func stopClipboardDelivery() {
        clipboardLifecycleLock.withLock {
            clipboardDeliveryEnabled = false
        }
    }

    func deliverFileTransferEvent(_ event: CoreFileTransferEvent) {
        queue.async { [self] in
            guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
                return
            }
            _ = fileTransferUploadReadAdapter.observe(event)
            switch fileTransferReceiveAdapter.observe(event) {
            case .unhandled, .forward:
                onFileTransferEvent(event)
            case .suppress:
                return
            case .cancelRequired:
                _ = fileTransferCancelRelay.cancel(
                    sessionEpoch: event.sessionEpoch,
                    transferID: event.transferID
                )
            }
        }
    }

    func deliverFileTransferList(_ event: CoreFileTransferListEvent) {
        queue.async { [self] in
            guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
                return
            }
            onFileTransferList(event)
        }
    }

    func deliverFileTransferManifest(_ event: CoreFileTransferManifestEvent) {
        queue.async { [self] in
            guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
                return
            }
            onFileTransferManifest(event)
        }
    }

    func deliverFileTransferReceiveBlock(_ block: CoreFileTransferReceiveBlock) {
        queue.async { [self] in
            guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
                return
            }
            switch fileTransferReceiveAdapter.receive(block) {
            case .unhandled, .accepted:
                onFileTransferReceiveBlock(block)
            case .cancelRequired:
                _ = fileTransferCancelRelay.cancel(
                    sessionEpoch: block.sessionEpoch,
                    transferID: block.transferID
                )
            }
        }
    }

    func beginFileTransferReceive(
        _ request: ViewerFileTransferDownloadRequest,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ) -> Bool {
        fileTransferReceiveAdapter.begin(
            request,
            destinationOwner: destinationOwner,
            onEvent: onEvent
        )
    }

    func beginFileTransferUpload(
        _ request: ViewerFileTransferUploadRequest,
        sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Bool {
        fileTransferLifecycleLock.withLock { fileTransferDeliveryEnabled }
            && fileTransferUploadReadAdapter.begin(
                request,
                sourceOwner: sourceOwner
            )
    }

    func readFileTransferUpload(
        sessionEpoch: UInt64,
        transferID: Int32,
        sourceToken: UInt64,
        fileNumber: UInt32,
        offset: UInt64,
        buffer: UnsafeMutablePointer<UInt8>,
        length: Int
    ) -> ViewerFileTransferUploadReadAdapterResult {
        guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
            return .rejected
        }
        return fileTransferUploadReadAdapter.read(
            sessionEpoch: sessionEpoch,
            transferID: transferID,
            sourceToken: sourceToken,
            fileNumber: fileNumber,
            offset: offset,
            buffer: buffer,
            length: length
        )
    }

    @discardableResult
    func rollbackFileTransferReceive(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        fileTransferReceiveAdapter.rollback(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
    }

    @discardableResult
    func rollbackFileTransferUpload(sessionEpoch: UInt64, transferID: Int32) -> Bool {
        fileTransferUploadReadAdapter.rollback(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
    }

    func stopFileTransferDelivery() {
        fileTransferLifecycleLock.withLock {
            fileTransferDeliveryEnabled = false
        }
        fileTransferReceiveAdapter.teardownAll()
        fileTransferUploadReadAdapter.teardownAll()
        fileTransferCancelRelay.unbind()
    }
}

private let stateCallback: RDNStateCallback = { context, state, code, message in
    guard let context else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let event = CoreStateEvent(
        state: CoreConnectionState(rawValue: Int32(state.rawValue)) ?? .error,
        code: code,
        message: message.map { String(cString: $0) } ?? ""
    )
    box.queue.async { box.onState(event) }
}

private let displayCatalogCallback: RDNDisplayCatalogCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        let status = CoreDisplayCatalogStatus(rawValue: raw.status),
        raw.entry_count <= Int(RDN_MAX_DISPLAY_CATALOG_ENTRIES),
        (raw.entry_count == 0) == (raw.entries == nil),
        raw.selected_display_known
            ? raw.selected_display_index != UInt32(RDN_DISPLAY_INDEX_UNKNOWN)
            : raw.selected_display_index == UInt32(RDN_DISPLAY_INDEX_UNKNOWN)
    else { return }
    var entries: [CoreDisplayCatalogEntry] = []
    entries.reserveCapacity(raw.entry_count)
    if let rawEntries = raw.entries {
        for offset in 0..<raw.entry_count {
            let entry = rawEntries[offset]
            guard
                entry.name_length <= Int(RDN_MAX_DISPLAY_NAME_UTF8_BYTES),
                (entry.name_length == 0) == (entry.name_utf8 == nil)
            else { return }
            let name: String
            if let bytes = entry.name_utf8 {
                let data = Data(bytes: bytes, count: entry.name_length)
                guard let copied = String(data: data, encoding: .utf8) else { return }
                name = copied
            } else {
                name = ""
            }
            guard let projected = CoreDisplayCatalogEntry(
                displayIndex: entry.display_index,
                x: entry.x,
                y: entry.y,
                width: entry.width,
                height: entry.height,
                online: entry.online,
                scale: entry.scale,
                name: name
            ) else { return }
            entries.append(projected)
        }
    }
    guard let event = CoreDisplayCatalogEvent(
        connectionEpoch: raw.connection_epoch,
        catalogRevision: raw.catalog_revision,
        status: status,
        selectedDisplayIndex: raw.selected_display_known ? raw.selected_display_index : nil,
        entries: entries
    ) else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.observeDisplayCatalog(event)
}

private let displaySelectionCallback: RDNDisplaySelectionCallback = { context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        let result = CoreDisplaySelectionResult(rawValue: raw.result),
        let failure = CoreDisplaySelectionFailure(rawValue: raw.failure),
        let event = CoreDisplaySelectionEvent(
            connectionEpoch: raw.connection_epoch,
            commandID: raw.command_id,
            catalogRevision: raw.catalog_revision,
            displayIndex: raw.display_index,
            result: result,
            failure: failure
        )
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverDisplaySelection(event)
}

private let videoCallback: RDNVideoCallback = { context, framePointer in
    guard let context, let framePointer else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let frame = framePointer.pointee
    guard
        frame.abi_version == RDN_ABI_VERSION,
        let bytes = frame.data,
        box.acceptsVideoFrame(
            connectionEpoch: frame.connection_epoch,
            catalogRevision: frame.display_catalog_revision,
            displayIndex: frame.display
        )
    else { return }
    // The Rust pointer is callback-scoped. Copy only compressed packet bytes.
    let data = Data(bytes: bytes, count: frame.length)
    let packet = CoreVideoPacket(
        codec: CoreVideoCodec(rawValue: Int32(frame.codec.rawValue)) ?? .unknown,
        format: CorePacketFormat(rawValue: Int32(frame.packet_format.rawValue)) ?? .unknown,
        data: data,
        sequence: frame.sequence,
        timestampUS: frame.timestamp_us,
        flags: frame.flags,
        width: frame.width,
        height: frame.height,
        display: frame.display,
        connectionEpoch: frame.connection_epoch,
        displayCatalogRevision: frame.display_catalog_revision
    )
    box.deliverVideo(packet)
}

private let metricsCallback: RDNMetricsCallback = { context, metricsPointer in
    guard let context, let metricsPointer else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let raw = metricsPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION else { return }
    let metrics = CoreRuntimeMetrics(
        remoteFPS: raw.remote_fps,
        networkDelayMS: raw.network_delay_ms,
        targetBitrate: raw.target_bitrate
    )
    box.queue.async { box.onMetrics(metrics) }
}

private let clipboardTextCallback: RDNClipboardTextCallback = { context, utf8, length in
    guard
        let context,
        let utf8,
        length > 0,
        length <= Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES)
    else { return }
    let data = Data(bytes: utf8, count: length)
    guard
        let text = String(data: data, encoding: .utf8),
        !text.contains("\0")
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverClipboardText(text)
}

private func copiedOptionalClipboardUTF8(
    _ utf8: UnsafePointer<UInt8>?,
    length: Int,
    maximum: Int
) -> (valid: Bool, text: String?) {
    guard let utf8 else { return (length == 0, nil) }
    guard length > 0, length <= maximum else { return (false, nil) }
    let data = Data(bytes: utf8, count: length)
    guard
        let text = String(data: data, encoding: .utf8),
        !text.contains("\0")
    else { return (false, nil) }
    return (true, text)
}

private func optionalClipboardUTF8Data(
    _ text: String?,
    maximum: Int
) -> (valid: Bool, data: Data?) {
    guard let text else { return (true, nil) }
    let data = Data(text.utf8)
    guard !data.isEmpty, data.count <= maximum, !text.contains("\0") else {
        return (false, nil)
    }
    return (true, data)
}

private let clipboardRichTextCallback: RDNClipboardRichTextCallback = {
    context, payloadPointer in
    guard let context, let payloadPointer else { return }
    let raw = payloadPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION else { return }
    let plain = copiedOptionalClipboardUTF8(
        raw.plain_utf8,
        length: raw.plain_length,
        maximum: Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES)
    )
    let rtf = copiedOptionalClipboardUTF8(
        raw.rtf_utf8,
        length: raw.rtf_length,
        maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES)
    )
    let html = copiedOptionalClipboardUTF8(
        raw.html_utf8,
        length: raw.html_length,
        maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES)
    )
    guard plain.valid, rtf.valid, html.valid, rtf.text != nil || html.text != nil else {
        return
    }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverClipboardRichText(CoreClipboardRichTextPayload(
        plainText: plain.text,
        rtf: rtf.text,
        html: html.text
    ))
}

package let maximumClipboardImageBytes = Int(RDN_MAX_CLIPBOARD_IMAGE_BYTES)
package let maximumClipboardSVGUTF8Bytes = Int(RDN_MAX_CLIPBOARD_SVG_UTF8_BYTES)
private let maximumClipboardImageDimension = UInt32(RDN_MAX_CLIPBOARD_IMAGE_DIMENSION)
private let maximumClipboardImagePixels = Int(RDN_MAX_CLIPBOARD_IMAGE_PIXELS)

package func clipboardImagePixelCount(width: UInt32, height: UInt32) -> Int? {
    guard
        width > 0,
        height > 0,
        width <= maximumClipboardImageDimension,
        height <= maximumClipboardImageDimension
    else { return nil }
    let (pixels, overflow) = Int(width).multipliedReportingOverflow(by: Int(height))
    guard !overflow, pixels <= maximumClipboardImagePixels else { return nil }
    return pixels
}

private func clipboardPNGUInt32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count - 4 else { return nil }
    return (UInt32(data[data.startIndex + offset]) << 24)
        | (UInt32(data[data.startIndex + offset + 1]) << 16)
        | (UInt32(data[data.startIndex + offset + 2]) << 8)
        | UInt32(data[data.startIndex + offset + 3])
}

private func clipboardPNGChunkIs(_ data: Data, at offset: Int, _ bytes: [UInt8]) -> Bool {
    guard offset >= 0, offset <= data.count - bytes.count else { return false }
    return bytes.enumerated().allSatisfy { index, byte in
        data[data.startIndex + offset + index] == byte
    }
}

private func clipboardPNGIsCanonical(_ data: Data) -> Bool {
    let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    guard
        data.count >= 33,
        clipboardPNGChunkIs(data, at: 0, signature)
    else { return false }

    var offset = 8
    var hasDimensions = false
    var hasImageData = false
    while true {
        guard let rawLength = clipboardPNGUInt32(data, at: offset) else { return false }
        let length = Int(rawLength)
        let headerEnd = offset.addingReportingOverflow(8)
        guard !headerEnd.overflow else { return false }
        let dataEnd = headerEnd.partialValue.addingReportingOverflow(length)
        guard !dataEnd.overflow else { return false }
        let chunkEnd = dataEnd.partialValue.addingReportingOverflow(4)
        guard !chunkEnd.overflow, chunkEnd.partialValue <= data.count else { return false }

        let typeOffset = offset + 4
        if clipboardPNGChunkIs(data, at: typeOffset, [0x49, 0x48, 0x44, 0x52]) {
            guard offset == 8, length == 13, !hasDimensions else { return false }
            guard
                let width = clipboardPNGUInt32(data, at: headerEnd.partialValue),
                let height = clipboardPNGUInt32(data, at: headerEnd.partialValue + 4),
                clipboardImagePixelCount(width: width, height: height) != nil
            else { return false }
            let bitDepth = data[data.startIndex + headerEnd.partialValue + 8]
            let colorType = data[data.startIndex + headerEnd.partialValue + 9]
            let validDepth: Bool
            switch colorType {
            case 0: validDepth = [1, 2, 4, 8, 16].contains(bitDepth)
            case 2, 4, 6: validDepth = [8, 16].contains(bitDepth)
            case 3: validDepth = [1, 2, 4, 8].contains(bitDepth)
            default: validDepth = false
            }
            guard
                validDepth,
                data[data.startIndex + headerEnd.partialValue + 10] == 0,
                data[data.startIndex + headerEnd.partialValue + 11] == 0,
                data[data.startIndex + headerEnd.partialValue + 12] <= 1
            else { return false }
            hasDimensions = true
        } else if clipboardPNGChunkIs(data, at: typeOffset, [0x49, 0x44, 0x41, 0x54]) {
            guard hasDimensions else { return false }
            if length > 0 { hasImageData = true }
        } else if clipboardPNGChunkIs(data, at: typeOffset, [0x49, 0x45, 0x4e, 0x44]) {
            return length == 0 && hasDimensions && hasImageData && chunkEnd.partialValue == data.count
        } else if !hasDimensions {
            return false
        }
        offset = chunkEnd.partialValue
    }
}

private func clipboardSVGIsCanonical(_ svg: String) -> Bool {
    guard !svg.isEmpty, !svg.contains("\0") else { return false }
    var remainder = svg.drop(while: {
        $0 == "\u{feff}" || $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n"
    })
    if remainder.hasPrefix("<?xml") {
        guard let end = remainder.prefix(1024).range(of: "?>") else { return false }
        remainder = remainder[end.upperBound...].drop(while: { $0.isWhitespace })
    }
    guard
        remainder.range(of: "<!doctype", options: .caseInsensitive) == nil,
        remainder.hasPrefix("<svg")
    else { return false }
    let afterRoot = remainder.dropFirst(4)
    guard let first = afterRoot.first, first == ">" || first.isWhitespace else { return false }
    return afterRoot.contains(">")
}

package func normalizedClipboardImage(
    _ payload: CoreClipboardImagePayload
) -> (format: UInt32, data: Data, width: UInt32, height: UInt32)? {
    switch payload {
    case .rgba(let width, let height, let pixels):
        guard let pixelCount = clipboardImagePixelCount(width: width, height: height) else {
            return nil
        }
        let (expectedBytes, overflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard
            !overflow,
            expectedBytes == pixels.count,
            pixels.count <= maximumClipboardImageBytes
        else { return nil }
        return (
            UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue),
            pixels,
            width,
            height
        )
    case .png(let data):
        guard data.count <= maximumClipboardImageBytes, clipboardPNGIsCanonical(data) else {
            return nil
        }
        return (UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue), data, 0, 0)
    case .svg(let svg):
        let data = Data(svg.utf8)
        guard
            data.count <= maximumClipboardSVGUTF8Bytes,
            clipboardSVGIsCanonical(svg)
        else { return nil }
        return (UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue), data, 0, 0)
    }
}

private let clipboardImageCallback: RDNClipboardImageCallback = { context, payloadPointer in
    guard let context, let payloadPointer else { return }
    let raw = payloadPointer.pointee
    guard raw.abi_version == RDN_ABI_VERSION, let bytes = raw.data, raw.length > 0 else {
        return
    }
    switch raw.format {
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue):
        guard
            let pixelCount = clipboardImagePixelCount(width: raw.width, height: raw.height),
            raw.length == pixelCount * 4,
            raw.length <= maximumClipboardImageBytes
        else { return }
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue):
        guard raw.width == 0, raw.height == 0, raw.length <= maximumClipboardImageBytes else {
            return
        }
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue):
        guard raw.width == 0, raw.height == 0, raw.length <= maximumClipboardSVGUTF8Bytes else {
            return
        }
    default:
        return
    }
    let data = Data(bytes: bytes, count: raw.length)
    let candidate: CoreClipboardImagePayload
    switch raw.format {
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue):
        candidate = .rgba(width: raw.width, height: raw.height, pixels: data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue):
        candidate = .png(data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue):
        guard let svg = String(data: data, encoding: .utf8) else { return }
        candidate = .svg(svg)
    default:
        return
    }
    guard let normalized = normalizedClipboardImage(candidate) else { return }
    let payload: CoreClipboardImagePayload
    switch normalized.format {
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_RGBA.rawValue):
        payload = .rgba(
            width: normalized.width,
            height: normalized.height,
            pixels: normalized.data
        )
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_PNG.rawValue):
        payload = .png(normalized.data)
    case UInt32(RDN_CLIPBOARD_IMAGE_FORMAT_SVG.rawValue):
        guard let svg = String(data: normalized.data, encoding: .utf8) else { return }
        payload = .svg(svg)
    default:
        return
    }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverClipboardImage(payload)
}

private let fileTransferEventCallback: RDNFileTransferEventCallback = {
    context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        raw.current_file_number >= -1,
        let kind = CoreFileTransferEventKind(rawValue: raw.kind),
        let failure = CoreFileTransferFailure(rawValue: raw.failure),
        let event = CoreFileTransferEvent(
            sessionEpoch: raw.session_epoch,
            transferID: raw.transfer_id,
            sequence: raw.sequence,
            kind: kind,
            failure: failure,
            currentFileNumber: raw.current_file_number >= 0
                ? Int(raw.current_file_number)
                : nil,
            filesCompleted: raw.files_completed,
            totalFiles: raw.total_files,
            bytesCompleted: raw.bytes_completed,
            totalBytes: raw.total_bytes,
            bytesPerSecond: raw.bytes_per_second
        )
    else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferEvent(event)
}

private let fileTransferListCallback: RDNFileTransferListCallback = {
    context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        raw.session_epoch > 0,
        raw.request_id > 0,
        let status = CoreFileTransferListStatus(rawValue: raw.status),
        raw.entry_count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES)
    else { return }

    var entries: [CoreFileTransferListEntry] = []
    entries.reserveCapacity(raw.entry_count)
    if raw.entry_count > 0 {
        guard let rawEntries = raw.entries else { return }
        for index in 0..<raw.entry_count {
            let rawEntry = rawEntries.advanced(by: index).pointee
            guard
                let kind = CoreFileTransferListEntryKind(rawValue: rawEntry.kind),
                rawEntry.relative_path_length > 0,
                rawEntry.relative_path_length <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                let pathBytes = rawEntry.relative_path_utf8
            else { return }
            let pathData = Data(bytes: pathBytes, count: rawEntry.relative_path_length)
            guard let relativePath = String(data: pathData, encoding: .utf8) else { return }
            entries.append(CoreFileTransferListEntry(
                kind: kind,
                relativePath: relativePath,
                size: rawEntry.size,
                modifiedTime: rawEntry.modified_time
            ))
        }
    } else if raw.entries != nil {
        return
    }
    guard let event = CoreFileTransferListEvent(
        sessionEpoch: raw.session_epoch,
        requestID: raw.request_id,
        status: status,
        entries: entries
    ) else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferList(event)
}

private let fileTransferManifestCallback: RDNFileTransferManifestCallback = {
    context, eventPointer in
    guard let context, let eventPointer else { return }
    let raw = eventPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        raw.session_epoch > 0,
        raw.request_id > 0,
        let status = CoreFileTransferListStatus(rawValue: raw.status),
        let part = CoreFileTransferManifestPartKind(rawValue: raw.part),
        raw.entry_count <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES)
    else { return }

    var entries: [CoreFileTransferListEntry] = []
    entries.reserveCapacity(raw.entry_count)
    if raw.entry_count > 0 {
        guard let rawEntries = raw.entries else { return }
        for index in 0..<raw.entry_count {
            let rawEntry = rawEntries.advanced(by: index).pointee
            guard
                let kind = CoreFileTransferListEntryKind(rawValue: rawEntry.kind),
                rawEntry.relative_path_length > 0,
                rawEntry.relative_path_length
                    <= Int(RDN_MAX_FILE_TRANSFER_LIST_METADATA_UTF8_BYTES),
                let pathBytes = rawEntry.relative_path_utf8
            else { return }
            let pathData = Data(bytes: pathBytes, count: rawEntry.relative_path_length)
            guard let relativePath = String(data: pathData, encoding: .utf8) else { return }
            entries.append(CoreFileTransferListEntry(
                kind: kind,
                relativePath: relativePath,
                size: rawEntry.size,
                modifiedTime: rawEntry.modified_time
            ))
        }
    } else if raw.entries != nil {
        return
    }
    guard let event = CoreFileTransferManifestEvent(
        sessionEpoch: raw.session_epoch,
        requestID: raw.request_id,
        status: status,
        part: part,
        entries: entries
    ) else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferManifest(event)
}

private let fileTransferReceiveBlockCallback: RDNFileTransferReceiveBlockCallback = {
    context, blockPointer in
    guard let context, let blockPointer else { return }
    let raw = blockPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        raw.length > 0,
        raw.length <= CoreFileTransferReceiveBlock.maximumPayloadBytes,
        let bytes = raw.data
    else { return }
    let payload = Data(bytes: bytes, count: raw.length)
    guard let block = CoreFileTransferReceiveBlock(
        sessionEpoch: raw.session_epoch,
        transferID: raw.transfer_id,
        fileNumber: raw.file_number,
        payload: payload
    ) else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    box.deliverFileTransferReceiveBlock(block)
}

private let fileTransferUploadReadCallback: RDNFileTransferUploadReadCallback = {
    context, requestPointer, bytesWrittenPointer in
    guard let bytesWrittenPointer else {
        return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
    }
    bytesWrittenPointer.pointee = 0
    guard let context, let requestPointer else {
        return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
    }
    let raw = requestPointer.pointee
    guard
        raw.abi_version == RDN_ABI_VERSION,
        raw.session_epoch > 0,
        raw.transfer_id > 0,
        raw.source_token > 0,
        raw.length > 0,
        raw.length <= CoreFileTransferReceiveBlock.maximumPayloadBytes,
        let buffer = raw.buffer
    else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    switch box.readFileTransferUpload(
        sessionEpoch: raw.session_epoch,
        transferID: raw.transfer_id,
        sourceToken: raw.source_token,
        fileNumber: raw.file_number,
        offset: raw.offset,
        buffer: buffer,
        length: raw.length
    ) {
    case .success(let bytesWritten):
        guard bytesWritten == raw.length else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        bytesWrittenPointer.pointee = bytesWritten
        return 0
    case .rejected:
        return Int32(RDN_CLIENT_ERR_VALIDATION)
    }
}

public final class RustDeskCoreClient: @unchecked Sendable {
    public static let expectedUpstreamCommit = "6c578292e8ebbbec708b76986ba8c4bc7c509747"
    public static let abiVersion = UInt32(RDN_ABI_VERSION)

    private let library: OpaquePointer
    private let client: OpaquePointer
    private let callbackBox: CallbackBox
    private let lock = NSLock()
    private var disconnected = false

    public let upstreamCommit: String

    public init(
        libraryURL: URL,
        callbackQueue: DispatchQueue = DispatchQueue(label: "io.rustdesknative.core-events", qos: .userInteractive),
        onState: @escaping @Sendable (CoreStateEvent) -> Void,
        onVideo: @escaping @Sendable (CoreVideoPacket) -> Void,
        onMetrics: @escaping @Sendable (CoreRuntimeMetrics) -> Void,
        onDisplayCatalog: @escaping @Sendable (CoreDisplayCatalogEvent) -> Void = { _ in },
        onDisplaySelection: @escaping @Sendable (CoreDisplaySelectionEvent) -> Void = { _ in },
        onClipboardText: @escaping @Sendable (String) -> Void = { _ in },
        onClipboardRichText: @escaping @Sendable (CoreClipboardRichTextPayload) -> Void = { _ in },
        onClipboardImage: @escaping @Sendable (CoreClipboardImagePayload) -> Void = { _ in },
        onFileTransferEvent: @escaping @Sendable (CoreFileTransferEvent) -> Void = { _ in },
        onFileTransferList: @escaping @Sendable (CoreFileTransferListEvent) -> Void = { _ in },
        onFileTransferManifest: @escaping @Sendable (CoreFileTransferManifestEvent) -> Void = { _ in },
        onFileTransferReceiveBlock: @escaping @Sendable (CoreFileTransferReceiveBlock) -> Void = { _ in }
    ) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let library = libraryURL.path.withCString({
            rdn_shim_open($0, &error, error.count)
        }) else {
            throw CoreBridgeError.load(String(cString: error))
        }
        guard rdn_shim_abi_version(library) == RDN_ABI_VERSION else {
            rdn_shim_close(library)
            throw CoreBridgeError.load("ABI version mismatch")
        }
        let commit = rdn_shim_upstream_commit(library).map { String(cString: $0) } ?? ""
        guard commit == Self.expectedUpstreamCommit else {
            rdn_shim_close(library)
            throw CoreBridgeError.invalidUpstreamCommit(commit)
        }

        let fileTransferCancelRelay = FileTransferCancelRelay()
        let fileTransferReceiveAdapter = ViewerFileTransferReceiveAdapter()
        let fileTransferUploadReadAdapter = ViewerFileTransferUploadReadAdapter()
        let callbackBox = CallbackBox(
            queue: callbackQueue,
            onState: onState,
            onVideo: onVideo,
            onDisplayCatalog: onDisplayCatalog,
            onDisplaySelection: onDisplaySelection,
            onMetrics: onMetrics,
            onClipboardText: onClipboardText,
            onClipboardRichText: onClipboardRichText,
            onClipboardImage: onClipboardImage,
            onFileTransferEvent: onFileTransferEvent,
            onFileTransferList: onFileTransferList,
            onFileTransferManifest: onFileTransferManifest,
            onFileTransferReceiveBlock: onFileTransferReceiveBlock,
            fileTransferCancelRelay: fileTransferCancelRelay,
            fileTransferReceiveAdapter: fileTransferReceiveAdapter,
            fileTransferUploadReadAdapter: fileTransferUploadReadAdapter
        )
        var callbacks = RDNCallbacks(
            abi_version: RDN_ABI_VERSION,
            on_state: stateCallback,
            on_video: videoCallback,
            on_display_catalog: displayCatalogCallback,
            on_display_selection: displaySelectionCallback,
            on_metrics: metricsCallback,
            on_clipboard_text: clipboardTextCallback,
            on_clipboard_rich_text: clipboardRichTextCallback,
            on_clipboard_image: clipboardImageCallback,
            on_file_transfer_event: fileTransferEventCallback,
            on_file_transfer_list: fileTransferListCallback,
            on_file_transfer_manifest: fileTransferManifestCallback,
            on_file_transfer_receive_block: fileTransferReceiveBlockCallback,
            on_file_transfer_upload_read: fileTransferUploadReadCallback
        )
        let context = Unmanaged.passUnretained(callbackBox).toOpaque()
        guard let client = rdn_shim_client_create(library, &callbacks, context) else {
            rdn_shim_close(library)
            throw CoreBridgeError.createClient
        }
        fileTransferCancelRelay.bind(library: library, client: client)
        self.library = library
        self.client = client
        self.callbackBox = callbackBox
        upstreamCommit = commit
    }

    deinit {
        disconnect()
        rdn_shim_client_destroy(library, client)
        rdn_shim_close(library)
        withExtendedLifetime(callbackBox) {}
    }

    public func connect(_ config: CoreConnectionConfig) throws {
        let result = config.rendezvousServer.withCString { server in
            config.serverPublicKey.withCString { key in
                config.peerID.withCString { peerID in
                    config.password.withCString { password in
                        var raw = RDNConnectionConfig(
                            abi_version: RDN_ABI_VERSION,
                            rendezvous_server: server,
                            server_public_key: key,
                            peer_id: peerID,
                            password: password,
                            force_relay: config.forceRelay,
                            receive_audio: config.receiveAudio,
                            receive_clipboard_text: config.receiveClipboardText,
                            send_clipboard_text: config.sendClipboardText,
                            receive_clipboard_rich_text: config.receiveClipboardRichText,
                            send_clipboard_rich_text: config.sendClipboardRichText,
                            receive_clipboard_image: config.receiveClipboardImage,
                            send_clipboard_image: config.sendClipboardImage,
                            enable_file_transfer: config.fileTransferEnabled,
                            file_transfer_session_epoch: config.fileTransferSessionEpoch
                        )
                        return rdn_shim_client_connect(library, client, &raw)
                    }
                }
            }
        }
        guard result == 0 else { throw CoreBridgeError.connect(result) }
    }

    public func disconnect() {
        let shouldDisconnect = lock.withLock {
            if disconnected { return false }
            disconnected = true
            return true
        }
        if shouldDisconnect {
            callbackBox.stopDisplayDelivery()
            callbackBox.stopClipboardDelivery()
            callbackBox.stopFileTransferDelivery()
            rdn_shim_client_disconnect(library, client)
        }
    }

    @discardableResult
    public func requestKeyframe(display: UInt32) -> Bool {
        rdn_shim_client_request_keyframe(library, client, display) == 0
    }

    @discardableResult
    public func selectDisplay(_ request: CoreDisplaySelectionRequest) -> Int32 {
        var raw = RDNDisplaySelectionRequest(
            abi_version: RDN_ABI_VERSION,
            connection_epoch: request.connectionEpoch,
            command_id: request.commandID,
            catalog_revision: request.catalogRevision,
            display_index: request.displayIndex
        )
        return rdn_shim_client_select_display(library, client, &raw)
    }

    @discardableResult
    public func sendPointer(_ event: CorePointerEvent) -> Int32 {
        var raw = RDNPointerEvent(
            abi_version: RDN_ABI_VERSION,
            kind: RDNPointerKind(rawValue: event.kind.rawValue),
            x: event.x,
            y: event.y,
            scroll_x: event.scrollX,
            scroll_y: event.scrollY,
            buttons: event.buttons.rawValue,
            modifiers: event.modifiers.rawValue
        )
        return rdn_shim_client_send_pointer(library, client, &raw)
    }

    @discardableResult
    public func sendKey(_ event: CoreKeyEvent) -> Int32 {
        let code: UInt32
        let scalar: UInt32
        switch event.key {
        case .character(let value):
            code = 0
            scalar = value.value
        case .special(let value):
            code = value.rawValue
            scalar = 0
        case .physical:
            code = 19
            scalar = 0
        }
        let hardwareKeycode: UInt32
        if case .physical(let value) = event.key {
            hardwareKeycode = UInt32(value)
        } else {
            hardwareKeycode = 0
        }
        var raw = RDNKeyEvent(
            abi_version: RDN_ABI_VERSION,
            code: RDNKeyCode(rawValue: code),
            unicode_scalar: scalar,
            hardware_keycode: hardwareKeycode,
            down: event.isDown,
            modifiers: event.modifiers.rawValue
        )
        return rdn_shim_client_send_key(library, client, &raw)
    }

    @discardableResult
    public func sendText(_ text: String) -> Int32 {
        let utf8 = Data(text.utf8)
        guard !utf8.isEmpty else { return -4 }
        return utf8.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return -4 }
            return rdn_shim_client_send_text(library, client, baseAddress, utf8.count)
        }
    }

    @discardableResult
    public func sendClipboardText(_ text: String) -> Int32 {
        let utf8 = Data(text.utf8)
        guard
            !utf8.isEmpty,
            utf8.count <= Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES),
            !text.contains("\0")
        else { return -4 }
        return utf8.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return -4 }
            return rdn_shim_client_send_clipboard_text(
                library,
                client,
                baseAddress,
                utf8.count
            )
        }
    }

    @discardableResult
    public func sendClipboardRichText(_ payload: CoreClipboardRichTextPayload) -> Int32 {
        guard payload.rtf != nil || payload.html != nil else { return -4 }
        let plain = optionalClipboardUTF8Data(
            payload.plainText,
            maximum: Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES)
        )
        let rtf = optionalClipboardUTF8Data(
            payload.rtf,
            maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES)
        )
        let html = optionalClipboardUTF8Data(
            payload.html,
            maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES)
        )
        guard plain.valid, rtf.valid, html.valid else { return -4 }
        return plain.data.withOptionalUnsafeBytes { plainBytes, plainLength in
            rtf.data.withOptionalUnsafeBytes { rtfBytes, rtfLength in
                html.data.withOptionalUnsafeBytes { htmlBytes, htmlLength in
                    var raw = RDNClipboardRichTextPayload(
                        abi_version: RDN_ABI_VERSION,
                        plain_utf8: plainBytes,
                        plain_length: plainLength,
                        rtf_utf8: rtfBytes,
                        rtf_length: rtfLength,
                        html_utf8: htmlBytes,
                        html_length: htmlLength
                    )
                    return rdn_shim_client_send_clipboard_rich_text(
                        library,
                        client,
                        &raw
                    )
                }
            }
        }
    }

    @discardableResult
    public func sendClipboardImage(_ payload: CoreClipboardImagePayload) -> Int32 {
        guard let normalized = normalizedClipboardImage(payload) else { return -4 }
        return normalized.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return -4 }
            var raw = RDNClipboardImagePayload(
                abi_version: RDN_ABI_VERSION,
                format: normalized.format,
                data: baseAddress,
                length: normalized.data.count,
                width: normalized.width,
                height: normalized.height
            )
            return rdn_shim_client_send_clipboard_image(library, client, &raw)
        }
    }

    @discardableResult
    public func cancelFileTransfer(sessionEpoch: UInt64, transferID: Int32) -> Int32 {
        guard sessionEpoch > 0, transferID > 0 else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        return rdn_shim_client_file_transfer_cancel(
            library,
            client,
            sessionEpoch,
            transferID
        )
    }

    @discardableResult
    public func requestFileTransferRootList(sessionEpoch: UInt64, requestID: Int32) -> Int32 {
        guard sessionEpoch > 0, requestID > 0 else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        return rdn_shim_client_file_transfer_list_root(
            library,
            client,
            sessionEpoch,
            requestID
        )
    }

    @discardableResult
    public func requestFileTransferRecursiveManifest(
        sessionEpoch: UInt64,
        requestID: Int32
    ) -> Int32 {
        guard sessionEpoch > 0, requestID > 0 else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        return rdn_shim_client_file_transfer_manifest_root(
            library,
            client,
            sessionEpoch,
            requestID
        )
    }

    /// Registers the path-free Rust download and its exact Swift destination
    /// route as one lifecycle. A rejected Core start rolls the route back.
    @discardableResult
    package func startFileTransferDownload(
        _ request: ViewerFileTransferDownloadRequest,
        manifestRequestID: Int32,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onReceiveEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void = { _ in }
    ) -> Int32 {
        guard let start = CoreFileTransferDownloadStart(
            request: request,
            manifestRequestID: manifestRequestID
        ) else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        guard callbackBox.beginFileTransferReceive(
            request,
            destinationOwner: destinationOwner,
            onEvent: onReceiveEvent
        ) else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        var raw = RDNFileTransferDownloadStart(
            abi_version: RDN_ABI_VERSION,
            session_epoch: start.sessionEpoch,
            manifest_request_id: start.manifestRequestID,
            transfer_id: start.transferID,
            total_files: start.totalFiles,
            total_bytes: start.totalBytes
        )
        let result = rdn_shim_client_file_transfer_download_start(library, client, &raw)
        if result != 0 {
            callbackBox.rollbackFileTransferReceive(
                sessionEpoch: request.sessionEpoch,
                transferID: request.transferID
            )
        }
        return result
    }

    /// Registers one exact path-free upload source. ABI v14 success means the
    /// Rust semantic job and Swift descriptor owner are paired; wire dispatch
    /// remains deliberately outside this contract step.
    @discardableResult
    package func startFileTransferUpload(
        _ request: ViewerFileTransferUploadRequest,
        sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Int32 {
        guard
            request.manifest.files.allSatisfy({ $0.modifiedTime >= 0 }),
            request.manifest.files.count
                + request.manifest.emptyDirectories.count <= Int(
                    RDN_MAX_FILE_TRANSFER_LIST_ENTRIES
                )
        else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }

        var allocations: [UnsafeMutablePointer<UInt8>] = []
        var entries: [RDNFileTransferListEntry] = []
        allocations.reserveCapacity(
            request.manifest.files.count
                + request.manifest.emptyDirectories.count
        )
        entries.reserveCapacity(allocations.capacity)

        func appendEntry(
            kind: UInt32,
            path: String,
            size: UInt64,
            modifiedTime: UInt64
        ) -> Bool {
            let utf8 = Data(path.utf8)
            guard !utf8.isEmpty else { return false }
            let allocation = UnsafeMutablePointer<UInt8>.allocate(
                capacity: utf8.count
            )
            utf8.copyBytes(to: allocation, count: utf8.count)
            allocations.append(allocation)
            entries.append(RDNFileTransferListEntry(
                kind: kind,
                relative_path_utf8: UnsafePointer(allocation),
                relative_path_length: utf8.count,
                size: size,
                modified_time: modifiedTime
            ))
            return true
        }

        for file in request.manifest.files {
            guard appendEntry(
                kind: UInt32(RDN_FILE_TRANSFER_LIST_ENTRY_FILE.rawValue),
                path: file.relativePath,
                size: file.size,
                modifiedTime: UInt64(file.modifiedTime)
            ) else {
                allocations.forEach { $0.deallocate() }
                return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
            }
        }
        for directory in request.manifest.emptyDirectories {
            guard appendEntry(
                kind: UInt32(RDN_FILE_TRANSFER_LIST_ENTRY_DIRECTORY.rawValue),
                path: directory,
                size: 0,
                modifiedTime: 0
            ) else {
                allocations.forEach { $0.deallocate() }
                return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
            }
        }
        defer { allocations.forEach { $0.deallocate() } }

        guard callbackBox.beginFileTransferUpload(
            request,
            sourceOwner: sourceOwner
        ) else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        let result = entries.withUnsafeBufferPointer { entriesPointer in
            var raw = RDNFileTransferUploadStart(
                abi_version: RDN_ABI_VERSION,
                session_epoch: request.sessionEpoch,
                transfer_id: request.transferID,
                source_token: request.source.token,
                entries: entriesPointer.baseAddress,
                entry_count: entriesPointer.count,
                total_bytes: request.manifest.totalBytes
            )
            return rdn_shim_client_file_transfer_upload_start(
                library,
                client,
                &raw
            )
        }
        if result != 0 {
            callbackBox.rollbackFileTransferUpload(
                sessionEpoch: request.sessionEpoch,
                transferID: request.transferID
            )
        }
        return result
    }

    @discardableResult
    package func discardFileTransferReceive(
        sessionEpoch: UInt64,
        transferID: Int32
    ) -> Bool {
        callbackBox.rollbackFileTransferReceive(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
    }

    @discardableResult
    package func discardFileTransferUpload(
        sessionEpoch: UInt64,
        transferID: Int32
    ) -> Bool {
        callbackBox.rollbackFileTransferUpload(
            sessionEpoch: sessionEpoch,
            transferID: transferID
        )
    }
}

private extension Optional where Wrapped == Data {
    func withOptionalUnsafeBytes<T>(
        _ body: (UnsafePointer<UInt8>?, Int) -> T
    ) -> T {
        guard let data = self else { return body(nil, 0) }
        return data.withUnsafeBytes { bytes in
            body(bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
