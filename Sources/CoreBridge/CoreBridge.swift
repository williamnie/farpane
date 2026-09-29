import CoreBridgeShim
import Foundation

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
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "io.rustdesknative.core-events", qos: .userInteractive),
        onState: @escaping @Sendable (CoreStateEvent) -> Void,
        onRemotePermission: @escaping @Sendable (CoreRemotePermissionEvent) -> Void = { _ in },
        onVideo: @escaping @Sendable (CoreVideoPacket) -> Void,
        onMetrics: @escaping @Sendable (CoreRuntimeMetrics) -> Void,
        onDisplayCatalog: @escaping @Sendable (CoreDisplayCatalogEvent) -> Void = { _ in },
        onDisplaySelection: @escaping @Sendable (CoreDisplaySelectionEvent) -> Void = { _ in },
        onClipboardText: @escaping @Sendable (String) -> Void = { _ in },
        onClipboardRichText: @escaping @Sendable (CoreClipboardRichTextPayload) -> Void = { _ in },
        onClipboardImage: @escaping @Sendable (CoreClipboardImagePayload) -> Void = { _ in },
        onFileTransferEvent: @escaping @Sendable (CoreFileTransferEvent) -> Void = { _ in },
        onFileTransferList: @escaping @Sendable (CoreFileTransferListEvent) -> Void = { _ in },
        onFileTransferManifest: @escaping @Sendable (CoreFileTransferManifestEvent) -> Void = { _ in
        },
        onFileTransferReceiveBlock: @escaping @Sendable (CoreFileTransferReceiveBlock) -> Void = {
            _ in
        }
    ) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let library = libraryURL.path.withCString({ rdn_shim_open($0, &error, error.count) })
        else { throw CoreBridgeError.load(String(cString: error)) }
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
            queue: callbackQueue, onState: onState, onRemotePermission: onRemotePermission,
            onVideo: onVideo, onDisplayCatalog: onDisplayCatalog,
            onDisplaySelection: onDisplaySelection, onMetrics: onMetrics,
            onClipboardText: onClipboardText, onClipboardRichText: onClipboardRichText,
            onClipboardImage: onClipboardImage, onFileTransferEvent: onFileTransferEvent,
            onFileTransferList: onFileTransferList, onFileTransferManifest: onFileTransferManifest,
            onFileTransferReceiveBlock: onFileTransferReceiveBlock,
            fileTransferCancelRelay: fileTransferCancelRelay,
            fileTransferReceiveAdapter: fileTransferReceiveAdapter,
            fileTransferUploadReadAdapter: fileTransferUploadReadAdapter)
        var callbacks = RDNCallbacks(
            abi_version: RDN_ABI_VERSION, on_state: stateCallback,
            on_remote_permission: remotePermissionCallback, on_video: videoCallback,
            on_display_catalog: displayCatalogCallback,
            on_display_selection: displaySelectionCallback, on_metrics: metricsCallback,
            on_clipboard_text: clipboardTextCallback,
            on_clipboard_rich_text: clipboardRichTextCallback,
            on_clipboard_image: clipboardImageCallback,
            on_file_transfer_event: fileTransferEventCallback,
            on_file_transfer_list: fileTransferListCallback,
            on_file_transfer_manifest: fileTransferManifestCallback,
            on_file_transfer_receive_block: fileTransferReceiveBlockCallback,
            on_file_transfer_upload_read: fileTransferUploadReadCallback)
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
                            abi_version: RDN_ABI_VERSION, rendezvous_server: server,
                            server_public_key: key, peer_id: peerID, password: password,
                            force_relay: config.forceRelay, receive_audio: config.receiveAudio,
                            receive_clipboard_text: config.receiveClipboardText,
                            send_clipboard_text: config.sendClipboardText,
                            receive_clipboard_rich_text: config.receiveClipboardRichText,
                            send_clipboard_rich_text: config.sendClipboardRichText,
                            receive_clipboard_image: config.receiveClipboardImage,
                            send_clipboard_image: config.sendClipboardImage,
                            enable_file_transfer: config.fileTransferEnabled,
                            file_transfer_session_epoch: config.fileTransferSessionEpoch)
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

    @discardableResult public func requestKeyframe(display: UInt32) -> Bool {
        rdn_shim_client_request_keyframe(library, client, display) == 0
    }

    @discardableResult public func selectDisplay(_ request: CoreDisplaySelectionRequest) -> Int32 {
        var raw = RDNDisplaySelectionRequest(
            abi_version: RDN_ABI_VERSION, connection_epoch: request.connectionEpoch,
            command_id: request.commandID, catalog_revision: request.catalogRevision,
            display_index: request.displayIndex)
        return rdn_shim_client_select_display(library, client, &raw)
    }

    @discardableResult public func sendPointer(_ event: CorePointerEvent) -> Int32 {
        var raw = RDNPointerEvent(
            abi_version: RDN_ABI_VERSION, kind: RDNPointerKind(rawValue: event.kind.rawValue),
            x: event.x, y: event.y, scroll_x: event.scrollX, scroll_y: event.scrollY,
            buttons: event.buttons.rawValue, modifiers: event.modifiers.rawValue)
        return rdn_shim_client_send_pointer(library, client, &raw)
    }

    @discardableResult public func sendKey(_ event: CoreKeyEvent) -> Int32 {
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
            abi_version: RDN_ABI_VERSION, code: RDNKeyCode(rawValue: code), unicode_scalar: scalar,
            hardware_keycode: hardwareKeycode, down: event.isDown,
            modifiers: event.modifiers.rawValue)
        return rdn_shim_client_send_key(library, client, &raw)
    }

    @discardableResult public func sendText(_ text: String) -> Int32 {
        let utf8 = Data(text.utf8)
        guard !utf8.isEmpty else { return -4 }
        return utf8.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return -4 }
            return rdn_shim_client_send_text(library, client, baseAddress, utf8.count)
        }
    }

    @discardableResult public func sendClipboardText(_ text: String) -> Int32 {
        let utf8 = Data(text.utf8)
        guard !utf8.isEmpty, utf8.count <= Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES),
            !text.contains("\0")
        else { return -4 }
        return utf8.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return -4 }
            return rdn_shim_client_send_clipboard_text(library, client, baseAddress, utf8.count)
        }
    }

    @discardableResult public func sendClipboardRichText(_ payload: CoreClipboardRichTextPayload)
        -> Int32
    {
        guard payload.rtf != nil || payload.html != nil else { return -4 }
        let plain = optionalClipboardUTF8Data(
            payload.plainText, maximum: Int(RDN_MAX_CLIPBOARD_TEXT_UTF8_BYTES))
        let rtf = optionalClipboardUTF8Data(
            payload.rtf, maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES))
        let html = optionalClipboardUTF8Data(
            payload.html, maximum: Int(RDN_MAX_CLIPBOARD_RICH_TEXT_UTF8_BYTES))
        guard plain.valid, rtf.valid, html.valid else { return -4 }
        return plain.data.withOptionalUnsafeBytes { plainBytes, plainLength in
            rtf.data.withOptionalUnsafeBytes { rtfBytes, rtfLength in
                html.data.withOptionalUnsafeBytes { htmlBytes, htmlLength in
                    var raw = RDNClipboardRichTextPayload(
                        abi_version: RDN_ABI_VERSION, plain_utf8: plainBytes,
                        plain_length: plainLength, rtf_utf8: rtfBytes, rtf_length: rtfLength,
                        html_utf8: htmlBytes, html_length: htmlLength)
                    return rdn_shim_client_send_clipboard_rich_text(library, client, &raw)
                }
            }
        }
    }

    @discardableResult public func sendClipboardImage(_ payload: CoreClipboardImagePayload) -> Int32
    {
        guard let normalized = normalizedClipboardImage(payload) else { return -4 }
        return normalized.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return -4 }
            var raw = RDNClipboardImagePayload(
                abi_version: RDN_ABI_VERSION, format: normalized.format, data: baseAddress,
                length: normalized.data.count, width: normalized.width, height: normalized.height)
            return rdn_shim_client_send_clipboard_image(library, client, &raw)
        }
    }

    @discardableResult public func cancelFileTransfer(sessionEpoch: UInt64, transferID: Int32)
        -> Int32
    {
        guard sessionEpoch > 0, transferID > 0 else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
        return rdn_shim_client_file_transfer_cancel(library, client, sessionEpoch, transferID)
    }

    @discardableResult public func requestFileTransferRootList(
        sessionEpoch: UInt64, requestID: Int32
    ) -> Int32 {
        guard sessionEpoch > 0, requestID > 0 else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
        return rdn_shim_client_file_transfer_list_root(library, client, sessionEpoch, requestID)
    }

    @discardableResult public func requestFileTransferRecursiveManifest(
        sessionEpoch: UInt64, requestID: Int32
    ) -> Int32 {
        guard sessionEpoch > 0, requestID > 0 else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
        return rdn_shim_client_file_transfer_manifest_root(library, client, sessionEpoch, requestID)
    }

    /// Registers the path-free Rust download and its exact Swift destination
    /// route as one lifecycle. A rejected Core start rolls the route back.
    @discardableResult package func startFileTransferDownload(
        _ request: ViewerFileTransferDownloadRequest, manifestRequestID: Int32,
        destinationOwner: ViewerFileTransferDestinationOwner,
        onReceiveEvent: @escaping @Sendable (ViewerFileTransferReceiveEvent) -> Void = { _ in }
    ) -> Int32 {
        guard
            let start = CoreFileTransferDownloadStart(
                request: request, manifestRequestID: manifestRequestID)
        else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
        guard
            callbackBox.beginFileTransferReceive(
                request, destinationOwner: destinationOwner, onEvent: onReceiveEvent)
        else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }
        var raw = RDNFileTransferDownloadStart(
            abi_version: RDN_ABI_VERSION, session_epoch: start.sessionEpoch,
            manifest_request_id: start.manifestRequestID, transfer_id: start.transferID,
            total_files: start.totalFiles, total_bytes: start.totalBytes)
        let result = rdn_shim_client_file_transfer_download_start(library, client, &raw)
        if result != 0 {
            callbackBox.rollbackFileTransferReceive(
                sessionEpoch: request.sessionEpoch, transferID: request.transferID)
        }
        return result
    }

    /// Registers one exact path-free upload source. ABI v14 success means the
    /// Rust semantic job and Swift descriptor owner are paired; wire dispatch
    /// remains deliberately outside this contract step.
    @discardableResult package func startFileTransferUpload(
        _ request: ViewerFileTransferUploadRequest, sourceOwner: ViewerFileTransferUploadSourceOwner
    ) -> Int32 {
        guard request.manifest.files.allSatisfy({ $0.modifiedTime >= 0 }),
            request.manifest.files.count + request.manifest.emptyDirectories.count
                <= Int(RDN_MAX_FILE_TRANSFER_LIST_ENTRIES)
        else { return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD) }

        var allocations: [UnsafeMutablePointer<UInt8>] = []
        var entries: [RDNFileTransferListEntry] = []
        allocations.reserveCapacity(
            request.manifest.files.count + request.manifest.emptyDirectories.count)
        entries.reserveCapacity(allocations.capacity)

        func appendEntry(kind: UInt32, path: String, size: UInt64, modifiedTime: UInt64) -> Bool {
            let utf8 = Data(path.utf8)
            guard !utf8.isEmpty else { return false }
            let allocation = UnsafeMutablePointer<UInt8>.allocate(capacity: utf8.count)
            utf8.copyBytes(to: allocation, count: utf8.count)
            allocations.append(allocation)
            entries.append(
                RDNFileTransferListEntry(
                    kind: kind, relative_path_utf8: UnsafePointer(allocation),
                    relative_path_length: utf8.count, size: size, modified_time: modifiedTime))
            return true
        }

        for file in request.manifest.files {
            guard
                appendEntry(
                    kind: UInt32(RDN_FILE_TRANSFER_LIST_ENTRY_FILE.rawValue),
                    path: file.relativePath, size: file.size,
                    modifiedTime: UInt64(file.modifiedTime))
            else {
                for allocation in allocations { allocation.deallocate() }
                return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
            }
        }
        for directory in request.manifest.emptyDirectories {
            guard
                appendEntry(
                    kind: UInt32(RDN_FILE_TRANSFER_LIST_ENTRY_DIRECTORY.rawValue), path: directory,
                    size: 0, modifiedTime: 0)
            else {
                for allocation in allocations { allocation.deallocate() }
                return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
            }
        }
        defer { for allocation in allocations { allocation.deallocate() } }

        guard callbackBox.beginFileTransferUpload(request, sourceOwner: sourceOwner) else {
            return Int32(RDN_CLIENT_ERR_INVALID_PAYLOAD)
        }
        let result = entries.withUnsafeBufferPointer { entriesPointer in
            var raw = RDNFileTransferUploadStart(
                abi_version: RDN_ABI_VERSION, session_epoch: request.sessionEpoch,
                transfer_id: request.transferID, source_token: request.source.token,
                entries: entriesPointer.baseAddress, entry_count: entriesPointer.count,
                total_bytes: request.manifest.totalBytes)
            return rdn_shim_client_file_transfer_upload_start(library, client, &raw)
        }
        if result != 0 {
            callbackBox.rollbackFileTransferUpload(
                sessionEpoch: request.sessionEpoch, transferID: request.transferID)
        }
        return result
    }

    @discardableResult package func discardFileTransferReceive(
        sessionEpoch: UInt64, transferID: Int32
    ) -> Bool {
        callbackBox.rollbackFileTransferReceive(sessionEpoch: sessionEpoch, transferID: transferID)
    }

    @discardableResult package func discardFileTransferUpload(
        sessionEpoch: UInt64, transferID: Int32
    ) -> Bool {
        callbackBox.rollbackFileTransferUpload(sessionEpoch: sessionEpoch, transferID: transferID)
    }
}
