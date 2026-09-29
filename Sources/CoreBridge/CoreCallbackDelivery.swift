import CoreBridgeShim
import Foundation

final class FileTransferCancelRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (library: OpaquePointer, client: OpaquePointer)?

    func bind(library: OpaquePointer, client: OpaquePointer) {
        lock.withLock {
            precondition(target == nil)
            target = (library, client)
        }
    }

    @discardableResult func cancel(sessionEpoch: UInt64, transferID: Int32) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let target else { return nil }
        return rdn_shim_client_file_transfer_cancel(
            target.library, target.client, sessionEpoch, transferID)
    }

    func unbind() { lock.withLock { target = nil } }
}

final class CallbackBox: @unchecked Sendable {
    let queue: DispatchQueue
    let onState: @Sendable (CoreStateEvent) -> Void
    let onRemotePermission: @Sendable (CoreRemotePermissionEvent) -> Void
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
        queue: DispatchQueue, onState: @escaping @Sendable (CoreStateEvent) -> Void,
        onRemotePermission: @escaping @Sendable (CoreRemotePermissionEvent) -> Void,
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
        self.onRemotePermission = onRemotePermission
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
            guard displayLifecycleLock.withLock({ displayProjection.isCurrent(event) }) else {
                return
            }
            onDisplayCatalog(event)
        }
    }

    func deliverDisplaySelection(_ event: CoreDisplaySelectionEvent) {
        queue.async { [self] in onDisplaySelection(event) }
    }

    func acceptsVideoFrame(connectionEpoch: UInt64, catalogRevision: UInt64, displayIndex: UInt32)
        -> Bool
    {
        displayLifecycleLock.withLock {
            displayProjection.acceptsFrame(
                connectionEpoch: connectionEpoch, catalogRevision: catalogRevision,
                displayIndex: displayIndex)
        }
    }

    func deliverVideo(_ packet: CoreVideoPacket) {
        queue.async { [self] in
            guard
                acceptsVideoFrame(
                    connectionEpoch: packet.connectionEpoch,
                    catalogRevision: packet.displayCatalogRevision, displayIndex: packet.display)
            else { return }
            onVideo(packet)
        }
    }

    func stopDisplayDelivery() { displayLifecycleLock.withLock { displayProjection.stop() } }

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
        clipboardLifecycleLock.withLock { clipboardDeliveryEnabled = false }
    }

    func deliverFileTransferEvent(_ event: CoreFileTransferEvent) {
        queue.async { [self] in
            guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
                return
            }
            _ = fileTransferUploadReadAdapter.observe(event)
            switch fileTransferReceiveAdapter.observe(event) {
            case .unhandled, .forward: onFileTransferEvent(event)
            case .suppress: return
            case .cancelRequired:
                _ = fileTransferCancelRelay.cancel(
                    sessionEpoch: event.sessionEpoch, transferID: event.transferID)
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
            case .unhandled, .accepted: onFileTransferReceiveBlock(block)
            case .cancelRequired:
                _ = fileTransferCancelRelay.cancel(
                    sessionEpoch: block.sessionEpoch, transferID: block.transferID)
            }
        }
    }

    func beginFileTransferReceive(
        _ request: ViewerFileTransferDownloadRequest,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void
    ) -> Bool {
        fileTransferReceiveAdapter.begin(
            request, destinationOwner: destinationOwner, onEvent: onEvent)
    }

    func beginFileTransferUpload(
        _ request: ViewerFileTransferUploadRequest, sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Bool {
        fileTransferLifecycleLock.withLock { fileTransferDeliveryEnabled }
            && fileTransferUploadReadAdapter.begin(request, sourceOwner: sourceOwner)
    }

    func readFileTransferUpload(
        sessionEpoch: UInt64, transferID: Int32, sourceToken: UInt64, fileNumber: UInt32,
        offset: UInt64, buffer: UnsafeMutablePointer<UInt8>, length: Int
    ) -> ViewerFileTransferUploadReadAdapterResult {
        guard fileTransferLifecycleLock.withLock({ fileTransferDeliveryEnabled }) else {
            return .rejected
        }
        return fileTransferUploadReadAdapter.read(
            sessionEpoch: sessionEpoch, transferID: transferID, sourceToken: sourceToken,
            fileNumber: fileNumber, offset: offset, buffer: buffer, length: length)
    }

    @discardableResult func rollbackFileTransferReceive(sessionEpoch: UInt64, transferID: Int32)
        -> Bool
    { fileTransferReceiveAdapter.rollback(sessionEpoch: sessionEpoch, transferID: transferID) }

    @discardableResult func rollbackFileTransferUpload(sessionEpoch: UInt64, transferID: Int32)
        -> Bool
    { fileTransferUploadReadAdapter.rollback(sessionEpoch: sessionEpoch, transferID: transferID) }

    func stopFileTransferDelivery() {
        fileTransferLifecycleLock.withLock { fileTransferDeliveryEnabled = false }
        fileTransferReceiveAdapter.teardownAll()
        fileTransferUploadReadAdapter.teardownAll()
        fileTransferCancelRelay.unbind()
    }
}
