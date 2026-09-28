import CoreBridgeShim
import Foundation

final class HostEventBox: @unchecked Sendable {
    let queue: DispatchQueue
    let onEvent: @Sendable (HostCoreEvent) -> Void

    init(queue: DispatchQueue, onEvent: @escaping @Sendable (HostCoreEvent) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }
}

let hostEventCallback: RdnHostEventCallback = { context, json, length in
    guard let context, let json, length > 0 else { return }
    let box = Unmanaged<HostEventBox>.fromOpaque(context).takeUnretainedValue()
    // The Rust pointer is callback-scoped; copy the envelope bytes now.
    let data = Data(bytes: json, count: length)
    guard let event = HostCoreEvent(rawJSON: data) else { return }
    box.queue.async { box.onEvent(event) }
}

/// Swift-side HostCore control surface (§6.3, §8.2). Wraps the shimmed
/// `rdn_host_*` ABI with one library handle per process; host and viewer
/// cores remain mutually exclusive (§18 rule 1).
public final class HostControlClient: @unchecked Sendable {
    public static let hostABIVersion = UInt32(RDN_HOST_ABI_VERSION)
    public static let hostMediaABIVersion = UInt32(RDN_HOST_MEDIA_ABI_VERSION)
    public static let expectedUpstreamCommit = RustDeskCoreClient.expectedUpstreamCommit

    private let library: OpaquePointer
    private let eventBox: HostEventBox
    private let lock = NSLock()
    private var host: OpaquePointer?
    private var stopped = false

    public let upstreamCommit: String
    public let hostUpstreamCommit: String

    /// Loads the core library and validates the host ABI surface. Does not
    /// switch the config root and does not create a host instance.
    public init(
        libraryURL: URL,
        eventQueue: DispatchQueue = DispatchQueue(
            label: "io.farpane.host-events", qos: .userInitiated),
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let library = libraryURL.path.withCString({ rdn_shim_open($0, &error, error.count) })
        else { throw HostControlError.load(String(cString: error)) }
        guard rdn_shim_host_available(library) != 0 else {
            rdn_shim_close(library)
            throw HostControlError.hostSurfaceUnavailable
        }
        let hostABI = rdn_shim_host_abi_version(library)
        guard hostABI == Self.hostABIVersion else {
            rdn_shim_close(library)
            throw HostControlError.abiMismatch(found: hostABI)
        }
        let mediaABI = rdn_shim_host_media_abi_version(library)
        guard mediaABI == Self.hostMediaABIVersion else {
            rdn_shim_close(library)
            throw HostControlError.mediaABIMismatch(found: mediaABI)
        }
        let commit = rdn_shim_upstream_commit(library).map { String(cString: $0) } ?? ""
        let hostCommit = rdn_shim_host_upstream_commit(library).map { String(cString: $0) } ?? ""
        guard commit == Self.expectedUpstreamCommit, hostCommit == Self.expectedUpstreamCommit
        else {
            rdn_shim_close(library)
            throw HostControlError.invalidUpstreamCommit(hostCommit.isEmpty ? commit : hostCommit)
        }
        self.library = library
        self.eventBox = HostEventBox(queue: eventQueue, onEvent: onEvent)
        upstreamCommit = commit
        hostUpstreamCommit = hostCommit
    }

    deinit {
        lock.lock()
        let handle = host
        host = nil
        lock.unlock()
        if let handle {
            rdn_shim_host_stop(library, handle, RDN_HOST_STOP_APP_EXIT)
            rdn_shim_host_destroy(library, handle)
        }
        rdn_shim_close(library)
        withExtendedLifetime(eventBox) {}
    }

    /// One-shot early config-root isolation (decision point B): must run
    /// before any RustDesk config access in the process and before `start()`.
    public func setConfigRoot(appName: String, org: String) throws {
        let result = appName.withCString { name in
            org.withCString { organization in
                rdn_shim_host_set_config_root(library, name, organization)
            }
        }
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.configRoot(result) }
    }

    /// Creates and starts the host instance. Requires a successful prior
    /// `setConfigRoot`; the core fails closed otherwise (§8.2).
    public func start(configuration: HostServerConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard host == nil else { return }
        var callbacks = RdnHostCallbacks(
            abi_version: Self.hostABIVersion, on_event: hostEventCallback,
            context: Unmanaged.passUnretained(eventBox).toOpaque())
        var handle: OpaquePointer?
        let created = configuration.rendezvousServer.withCString { rendezvousServer in
            configuration.relayServer.withCString { relayServer in
                configuration.serverPublicKey.withCString { serverPublicKey in
                    (configuration.audioInputDeviceName ?? "").withCString { audioInputDevice in
                        (configuration.fileTransferReceiveRoot ?? "").withCString {
                            fileTransferReceiveRoot in
                            var options = RdnHostCreateOptions(
                                abi_version: Self.hostABIVersion,
                                rendezvous_server: rendezvousServer, relay_server: relayServer,
                                server_public_key: serverPublicKey,
                                enable_clipboard_read: configuration.clipboardReadEnabled,
                                enable_clipboard_write: configuration.clipboardWriteEnabled,
                                enable_clipboard_rich_text_read: configuration
                                    .clipboardRichTextReadEnabled,
                                enable_clipboard_rich_text_write: configuration
                                    .clipboardRichTextWriteEnabled,
                                enable_clipboard_image_read: configuration
                                    .clipboardImageReadEnabled,
                                enable_clipboard_image_write: configuration
                                    .clipboardImageWriteEnabled,
                                enable_audio: configuration.audioEnabled,
                                audio_input_device: audioInputDevice,
                                enable_file_transfer: configuration.fileTransferEnabled,
                                file_transfer_receive_root: fileTransferReceiveRoot)
                            return rdn_shim_host_create(library, &options, &callbacks, &handle)
                        }
                    }
                }
            }
        }
        guard created == Int32(RDN_HOST_OK), let handle else {
            throw HostControlError.create(created)
        }
        let started = rdn_shim_host_start(library, handle)
        guard started == Int32(RDN_HOST_OK) else {
            rdn_shim_host_destroy(library, handle)
            throw HostControlError.start(started)
        }
        host = handle
        stopped = false
    }

    /// Withdraws registration for one strictly increasing sleep epoch. A
    /// successful return only means Rust accepted the signal; callers must
    /// still call `finishSleep(epoch:)` before treating the Host as suspended.
    public func beginSleep(epoch: UInt64) throws {
        try performSleepRecovery(.beginSleep, epoch: epoch)
    }

    /// Joins the withdrawn registration runtime and waits for the Rust-owned
    /// sleep assertion drop acknowledgement for the exact accepted epoch.
    public func finishSleep(epoch: UInt64) throws {
        try performSleepRecovery(.finishSleep, epoch: epoch)
    }

    /// Restarts registration for the exact suspended epoch. Acceptance is
    /// pending only; readiness must converge through a later authoritative
    /// snapshot with the same epoch, `running`, and registration `ready`.
    public func resumeAfterWake(epoch: UInt64) throws {
        try performSleepRecovery(.resumeAfterWake, epoch: epoch)
    }

    /// Synchronously retires the old registration runtime and starts its
    /// replacement for the exact next product path generation. Acceptance is
    /// pending only; callers must wait for a later authoritative snapshot.
    public func recoverNetworkPath(generation: UInt64) throws {
        guard generation > 0 else {
            throw HostControlError.networkPathRecovery(Int32(RDN_HOST_ERR_STALE_GENERATION))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = host else {
            throw HostControlError.networkPathRecovery(Int32(RDN_HOST_ERR_BAD_STATE))
        }
        let result = rdn_shim_host_recover_network_path(library, handle, generation)
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.networkPathRecovery(result)
        }
    }

    private func performSleepRecovery(_ operation: HostSleepRecoveryOperation, epoch: UInt64) throws
    {
        guard epoch > 0 else {
            throw HostControlError.sleepRecovery(operation, Int32(RDN_HOST_ERR_INVALID_ARG))
        }
        lock.lock()
        defer { lock.unlock() }
        guard let handle = host else {
            throw HostControlError.sleepRecovery(operation, Int32(RDN_HOST_ERR_BAD_STATE))
        }
        let result: Int32
        switch operation {
        case .beginSleep: result = rdn_shim_host_begin_sleep(library, handle, epoch)
        case .finishSleep: result = rdn_shim_host_finish_sleep(library, handle, epoch)
        case .resumeAfterWake: result = rdn_shim_host_resume_after_wake(library, handle, epoch)
        }
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.sleepRecovery(operation, result)
        }
    }

    /// Sends a versioned command envelope (§8.4). `payload` entries are merged
    /// into the envelope body.
    public func command(
        _ name: String, commandId: String = UUID().uuidString, payload: [String: Any] = [:]
    ) throws {
        let envelope = try HostCommandEnvelopePolicy.envelope(
            commandName: name, commandID: commandId, payload: payload)
        let data = try JSONSerialization.data(withJSONObject: envelope)
        lock.lock()
        let result: Int32
        if let handle = host {
            result = data.withUnsafeBytes { buffer in
                rdn_shim_host_command(
                    library, handle, buffer.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.command(result) }
    }

    /// Applies the one final local decision allowed for a pending connection.
    /// Rust remains authoritative for deadline, identity and prior-final state.
    public func resolvePendingApproval(
        connectionID: String, decision: HostApprovalDecision, commandId: String = UUID().uuidString
    ) throws {
        try command(
            decision.commandName, commandId: commandId, payload: ["connectionId": connectionID])
    }

    /// Revokes one capability only for the currently active, exact session.
    /// The Rust session broker validates identity and remains authoritative for
    /// the capability snapshot emitted after the connection applies the change.
    public func disableActiveSessionCapability(
        _ capability: HostSessionRevocableCapability, connectionID: String,
        commandId: String = UUID().uuidString
    ) throws {
        try command(
            capability.commandName, commandId: commandId, payload: ["connectionId": connectionID])
    }

    /// Requests ordered connection teardown for the exact active session.
    /// Repeating the request is idempotent while that session is still active.
    public func disconnectSession(connectionID: String, commandId: String = UUID().uuidString)
        throws
    {
        try command(
            "disconnectSession", commandId: commandId, payload: ["connectionId": connectionID])
    }

    public func revealTemporaryPassword(commandId: String) throws -> String {
        try command("revealTemporaryPassword", commandId: commandId)
        guard let password = try copySnapshot().revealedTemporaryPassword, !password.isEmpty else {
            throw HostControlError.snapshotDecode("temporary password unavailable")
        }
        return password
    }

    public func regenerateTemporaryPassword(commandId: String) throws {
        try command("regenerateTemporaryPassword", commandId: commandId)
    }

    public func clearPermanentPassword(commandId: String) throws {
        try command("clearPermanentPassword", commandId: commandId)
    }

    /// Sends a permanent password only through the mutable secret-buffer ABI.
    /// The supplied Data is zeroed on every return path and must not be reused.
    public func setPermanentPassword(
        _ passwordUTF8: inout Data, commandId: String = UUID().uuidString
    ) throws {
        let result = HostSecretBufferPolicy.withMutableBytes(&passwordUTF8) { bytes, count in
            lock.lock()
            defer { lock.unlock() }
            guard let handle = host else { return Int32(RDN_HOST_ERR_BAD_STATE) }
            return commandId.withCString { commandID in
                rdn_shim_host_set_permanent_password(library, handle, commandID, bytes, count)
            }
        }
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.permanentPassword(result) }
    }

    /// Copies the current snapshot (§8.3). The revealed temporary password is
    /// only present on the single copy following a reveal command (§9.2).
    public func copySnapshot() throws -> HostCoreSnapshot {
        var bytes = RdnHostOwnedBytes(data: nil, length: 0, capacity: 0)
        lock.lock()
        let result =
            host.map { rdn_shim_host_copy_snapshot(library, $0, &bytes) }
            ?? Int32(RDN_HOST_ERR_BAD_STATE)
        lock.unlock()
        guard result == Int32(RDN_HOST_OK), let data = bytes.data else {
            throw HostControlError.snapshot(result)
        }
        let payload = Data(bytes: data, count: bytes.length)
        rdn_shim_host_free_bytes(library, bytes)
        return try HostCoreSnapshot(rawJSON: payload)
    }

    public func setMediaCapabilities(hostInstanceID: String, capabilities: HostEncoderCapabilities)
        throws
    {
        lock.lock()
        let result: Int32
        if let handle = host {
            result = hostInstanceID.withCString { instanceID in
                var raw = RdnHostEncoderCapabilities(
                    abi_version: Self.hostMediaABIVersion, host_instance_id: instanceID,
                    h264_hardware: capabilities.h264Hardware ? 1 : 0,
                    h265_hardware: capabilities.h265Hardware ? 1 : 0,
                    max_width: capabilities.maxWidth, max_height: capabilities.maxHeight,
                    max_fps: capabilities.maxFPS)
                return rdn_shim_host_media_set_capabilities(library, handle, &raw)
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.media(result) }
    }

    public func submit(accessUnit: HostEncodedAccessUnit) throws {
        var flags: UInt32 = 0
        if accessUnit.isKeyframe { flags |= UInt32(RDN_HOST_MEDIA_FLAG_KEYFRAME) }
        if accessUnit.hasParameterSets { flags |= UInt32(RDN_HOST_MEDIA_FLAG_PARAMETER_SETS) }
        lock.lock()
        let result: Int32
        if let handle = host {
            result = accessUnit.hostInstanceID.withCString { instanceID in
                accessUnit.data.withUnsafeBytes { bytes in
                    var raw = RdnHostEncodedAccessUnit(
                        abi_version: Self.hostMediaABIVersion, host_instance_id: instanceID,
                        connection_epoch: accessUnit.connectionEpoch,
                        codec_epoch: accessUnit.codecEpoch, display_id: accessUnit.displayID,
                        display_revision: accessUnit.displayRevision,
                        codec: RdnHostMediaCodec(rawValue: accessUnit.codec.rawValue),
                        framing: RdnHostMediaFraming(rawValue: accessUnit.framing.rawValue),
                        flags: flags, pts_us: accessUnit.presentationTimeUS,
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: accessUnit.data.count)
                    return rdn_shim_host_media_submit_access_unit(library, handle, &raw)
                }
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.media(result) }
    }

    public func reportEncoderState(
        hostInstanceID: String, connectionEpoch: UInt64, codecEpoch: UInt64, codec: HostMediaCodec,
        hardwareAccelerated: Bool, softwareFallback: Bool, encoderID: String
    ) throws {
        lock.lock()
        let result: Int32
        if let handle = host {
            result = hostInstanceID.withCString { instanceID in
                encoderID.withCString { encoderID in
                    var raw = RdnHostEncoderState(
                        abi_version: Self.hostMediaABIVersion, host_instance_id: instanceID,
                        connection_epoch: connectionEpoch, codec_epoch: codecEpoch,
                        codec: RdnHostMediaCodec(rawValue: codec.rawValue),
                        hardware_accelerated: hardwareAccelerated ? 1 : 0,
                        software_fallback: softwareFallback ? 1 : 0, encoder_id: encoderID)
                    return rdn_shim_host_media_report_encoder_state(library, handle, &raw)
                }
            }
        } else {
            result = Int32(RDN_HOST_ERR_BAD_STATE)
        }
        lock.unlock()
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.media(result) }
    }

    /// Stops the host and releases the instance slot; the core rotates the
    /// temporary password on stop (§9.2). Idempotent.
    public func stop(reason: HostStopReason = .userRequest) throws {
        lock.lock()
        let handle = host
        host = nil
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard let handle, !alreadyStopped else { return }
        let result = rdn_shim_host_stop(
            library, handle, RdnHostStopReason(rawValue: reason.rawValue))
        rdn_shim_host_destroy(library, handle)
        guard result == Int32(RDN_HOST_OK) else { throw HostControlError.stop(result) }
    }
}
