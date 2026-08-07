import CoreBridgeShim
import Foundation

/// Contract errors for the Host Control ABI (§8.1). Codes mirror the stable
/// `RDN_HOST_ERR_*` values so callers can distinguish fail-closed states.
public enum HostControlError: Error, CustomStringConvertible {
    case load(String)
    case hostSurfaceUnavailable
    case abiMismatch(found: UInt32)
    case mediaABIMismatch(found: UInt32)
    case invalidUpstreamCommit(String)
    case configRoot(Int32)
    case create(Int32)
    case start(Int32)
    case command(Int32)
    case snapshot(Int32)
    case snapshotDecode(String)
    case stop(Int32)
    case media(Int32)

    public var description: String {
        switch self {
        case .load(let message): return "Host core load failed: \(message)"
        case .hostSurfaceUnavailable: return "core library has no host ABI surface"
        case .abiMismatch(let found): return "host ABI version mismatch: \(found)"
        case .mediaABIMismatch(let found): return "host media ABI version mismatch: \(found)"
        case .invalidUpstreamCommit(let commit): return "unexpected RustDesk core commit: \(commit)"
        case .configRoot(let code): return "config-root switch rejected: \(code)"
        case .create(let code): return "host create failed: \(code)"
        case .start(let code): return "host start failed: \(code)"
        case .command(let code): return "host command rejected: \(code)"
        case .snapshot(let code): return "host snapshot copy failed: \(code)"
        case .snapshotDecode(let message): return "host snapshot decode failed: \(message)"
        case .stop(let code): return "host stop failed: \(code)"
        case .media(let code): return "host media operation rejected: \(code)"
        }
    }

    public var isExpectedMediaDrop: Bool {
        guard case .media(let code) = self else { return false }
        return code == -8 || code == -7 || code == -3
    }
}

public enum HostStopReason: UInt32, Sendable {
    case userRequest = 0
    case appExit = 1
    case error = 2
}

/// Canonical self-hosted RustDesk server configuration. The public key is
/// hbbs `key.pub`; it authenticates the server and is never an SSH credential.
public struct HostServerConfiguration: Sendable {
    public let rendezvousServer: String
    public let relayServer: String
    public let serverPublicKey: String

    public init(rendezvousServer: String, relayServer: String = "", serverPublicKey: String) {
        self.rendezvousServer = rendezvousServer
        self.relayServer = relayServer
        self.serverPublicKey = serverPublicKey
    }
}

public enum HostMediaCodec: UInt32, Sendable {
    case h264 = 1
    case h265 = 2
}

public enum HostMediaFraming: UInt32, Sendable {
    case annexB = 1
    case avcc = 2
}

public struct HostEncoderCapabilities: Sendable {
    public let h264Hardware: Bool
    public let h265Hardware: Bool
    public let maxWidth: UInt32
    public let maxHeight: UInt32
    public let maxFPS: UInt32

    public init(
        h264Hardware: Bool,
        h265Hardware: Bool,
        maxWidth: UInt32,
        maxHeight: UInt32,
        maxFPS: UInt32
    ) {
        self.h264Hardware = h264Hardware
        self.h265Hardware = h265Hardware
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFPS = maxFPS
    }
}

public struct HostEncodedAccessUnit: Sendable {
    public let hostInstanceID: String
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec
    public let framing: HostMediaFraming
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let data: Data

    public init(
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        displayID: UInt64,
        displayRevision: UInt64,
        codec: HostMediaCodec,
        framing: HostMediaFraming,
        presentationTimeUS: UInt64,
        isKeyframe: Bool,
        hasParameterSets: Bool,
        data: Data
    ) {
        self.hostInstanceID = hostInstanceID
        self.connectionEpoch = connectionEpoch
        self.codecEpoch = codecEpoch
        self.displayID = displayID
        self.displayRevision = displayRevision
        self.codec = codec
        self.framing = framing
        self.presentationTimeUS = presentationTimeUS
        self.isKeyframe = isKeyframe
        self.hasParameterSets = hasParameterSets
        self.data = data
    }
}

/// Decoded minimal snapshot field set (§8.3). Raw JSON is kept for audit
/// logging; the temporary password value is only present for the one-shot
/// revealed copy (§9.2).
public struct HostCoreSnapshot: Sendable {
    public let schemaVersion: Int
    public let hostInstanceId: String
    public let hostState: String
    public let localId: String
    public let registrationStatus: String
    public let temporaryPasswordPolicy: String
    public let revealedTemporaryPassword: String?
    public let lastError: String?
    public let observedAt: UInt64
    public let rawJSON: Data
}

/// Versioned event envelope delivered on the host event channel (§8.5).
public struct HostCoreEvent: Sendable {
    public let schemaVersion: Int
    public let eventId: UInt64
    public let eventType: String
    public let hostInstanceId: String
    public let sentAt: UInt64
    public let rawJSON: Data

    /// Decodes the versioned event envelope copied from the Host Control ABI.
    /// Unknown schema versions and incomplete envelopes fail closed.
    public init?(rawJSON: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let schemaVersion = (envelope["schemaVersion"] as? NSNumber)?.intValue,
              schemaVersion == 1,
              let eventID = (envelope["eventId"] as? NSNumber)?.uint64Value,
              let eventType = envelope["eventType"] as? String,
              !eventType.isEmpty,
              let hostInstanceID = envelope["hostInstanceId"] as? String,
              !hostInstanceID.isEmpty,
              let sentAt = (envelope["sentAt"] as? NSNumber)?.uint64Value,
              sentAt > 0
        else { return nil }
        self.schemaVersion = schemaVersion
        self.eventId = eventID
        self.eventType = eventType
        self.hostInstanceId = hostInstanceID
        self.sentAt = sentAt
        self.rawJSON = rawJSON
    }
}

public struct HostMediaControl: Sendable {
    public enum Command: String, Sendable {
        case startCapture
        case stopCapture
        case reconfigure
        case requestIdr
    }

    public let command: Command
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec?
    public let width: UInt32?
    public let height: UInt32?
    public let framesPerSecond: UInt32?
    public let bitRate: UInt32?
    public let reason: String?
}

/// Low-frequency, sanitized evidence that a compressed access unit crossed
/// the existing RustDesk writer/ACK path. It deliberately contains no peer
/// identifier, encoded bytes, screen content, password, or server material.
public struct HostMediaDiagnostic: Sendable {
    public enum Kind: String, Sendable {
        case firstPacketDispatched
        case firstPacketAcknowledged
        case refreshKeyframeDispatched
    }

    public let kind: Kind
    public let connectionEpoch: UInt64
    public let codecEpoch: UInt64
    public let displayID: UInt64
    public let displayRevision: UInt64
    public let codec: HostMediaCodec
    public let framing: HostMediaFraming
    public let presentationTimeUS: UInt64
    public let isKeyframe: Bool
    public let hasParameterSets: Bool
    public let subscriberCount: UInt32
}

public extension HostCoreEvent {
    var mediaControl: HostMediaControl? {
        guard eventType == "mediaControl",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawCommand = payload["command"] as? String,
              let command = HostMediaControl.Command(rawValue: rawCommand)
        else { return nil }
        let codec: HostMediaCodec?
        switch payload["codec"] as? String {
        case "h264": codec = .h264
        case "h265": codec = .h265
        default: codec = nil
        }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  number.int64Value >= 0,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        func uint32(_ key: String) -> UInt32? {
            guard let number = payload[key] as? NSNumber else { return nil }
            return number.uint64Value <= UInt32.max ? number.uint32Value : nil
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId")
        else { return nil }
        let displayRevision = uint64("displayRevision") ?? 0
        if command == .reconfigure {
            guard codec != nil,
                  let width = uint32("width"), width > 0,
                  let height = uint32("height"), height > 0,
                  let fps = uint32("fps"), fps > 0,
                  displayRevision > 0
            else { return nil }
        }
        return HostMediaControl(
            command: command,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            codec: codec,
            width: uint32("width"),
            height: uint32("height"),
            framesPerSecond: uint32("fps"),
            bitRate: uint32("bitrate"),
            reason: payload["reason"] as? String
        )
    }

    var mediaDiagnostic: HostMediaDiagnostic? {
        guard eventType == "mediaDiagnostic",
              let object = try? JSONSerialization.jsonObject(with: rawJSON),
              let envelope = object as? [String: Any],
              let payload = envelope["payload"] as? [String: Any],
              let rawKind = payload["kind"] as? String,
              let kind = HostMediaDiagnostic.Kind(rawValue: rawKind),
              let codecName = payload["codec"] as? String,
              let framingName = payload["framing"] as? String,
              let isKeyframe = payload["keyframe"] as? Bool,
              let hasParameterSets = payload["hasParameterSets"] as? Bool
        else { return nil }
        func uint64(_ key: String) -> UInt64? {
            guard let number = payload[key] as? NSNumber,
                  number.int64Value >= 0,
                  number.doubleValue.rounded(.towardZero) == number.doubleValue
            else { return nil }
            return number.uint64Value
        }
        guard let connectionEpoch = uint64("connectionEpoch"), connectionEpoch > 0,
              let codecEpoch = uint64("codecEpoch"), codecEpoch > 0,
              let displayID = uint64("displayId"),
              let displayRevision = uint64("displayRevision"), displayRevision > 0,
              let presentationTimeUS = uint64("ptsUs"),
              let rawSubscriberCount = uint64("subscriberCount"),
              rawSubscriberCount > 0, rawSubscriberCount <= UInt32.max
        else { return nil }
        let codec: HostMediaCodec
        switch codecName {
        case "h264": codec = .h264
        case "h265": codec = .h265
        default: return nil
        }
        let framing: HostMediaFraming
        switch framingName {
        case "annexB": framing = .annexB
        case "avcc": framing = .avcc
        default: return nil
        }
        return HostMediaDiagnostic(
            kind: kind,
            connectionEpoch: connectionEpoch,
            codecEpoch: codecEpoch,
            displayID: displayID,
            displayRevision: displayRevision,
            codec: codec,
            framing: framing,
            presentationTimeUS: presentationTimeUS,
            isKeyframe: isKeyframe,
            hasParameterSets: hasParameterSets,
            subscriberCount: UInt32(rawSubscriberCount)
        )
    }

}

public extension HostMediaControl {
    func matchesRoute(_ other: HostMediaControl) -> Bool {
        connectionEpoch == other.connectionEpoch
            && codecEpoch == other.codecEpoch
            && displayID == other.displayID
            && (displayRevision == 0
                || other.displayRevision == 0
                || displayRevision == other.displayRevision)
    }
}

public extension HostMediaDiagnostic {
    func matchesRoute(_ route: HostMediaControl) -> Bool {
        connectionEpoch == route.connectionEpoch
            && codecEpoch == route.codecEpoch
            && displayID == route.displayID
            && displayRevision == route.displayRevision
    }
}

private final class HostEventBox: @unchecked Sendable {
    let queue: DispatchQueue
    let onEvent: @Sendable (HostCoreEvent) -> Void

    init(queue: DispatchQueue, onEvent: @escaping @Sendable (HostCoreEvent) -> Void) {
        self.queue = queue
        self.onEvent = onEvent
    }
}

private let hostEventCallback: RdnHostEventCallback = { context, json, length in
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
        eventQueue: DispatchQueue = DispatchQueue(label: "io.farpane.host-events", qos: .userInitiated),
        onEvent: @escaping @Sendable (HostCoreEvent) -> Void
    ) throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let library = libraryURL.path.withCString({
            rdn_shim_open($0, &error, error.count)
        }) else {
            throw HostControlError.load(String(cString: error))
        }
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
        guard commit == Self.expectedUpstreamCommit, hostCommit == Self.expectedUpstreamCommit else {
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
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.configRoot(result)
        }
    }

    /// Creates and starts the host instance. Requires a successful prior
    /// `setConfigRoot`; the core fails closed otherwise (§8.2).
    public func start(configuration: HostServerConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        guard host == nil else { return }
        var callbacks = RdnHostCallbacks(
            abi_version: Self.hostABIVersion,
            on_event: hostEventCallback,
            context: Unmanaged.passUnretained(eventBox).toOpaque()
        )
        var handle: OpaquePointer?
        let created = configuration.rendezvousServer.withCString { rendezvousServer in
            configuration.relayServer.withCString { relayServer in
                configuration.serverPublicKey.withCString { serverPublicKey in
                    var options = RdnHostCreateOptions(
                        abi_version: Self.hostABIVersion,
                        rendezvous_server: rendezvousServer,
                        relay_server: relayServer,
                        server_public_key: serverPublicKey
                    )
                    return rdn_shim_host_create(library, &options, &callbacks, &handle)
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

    /// Sends a versioned command envelope (§8.4). `payload` entries are merged
    /// into the envelope body.
    public func command(_ name: String, commandId: String = UUID().uuidString, payload: [String: Any] = [:]) throws {
        var envelope: [String: Any] = ["commandId": commandId, "name": name]
        for (key, value) in payload { envelope[key] = value }
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
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.command(result)
        }
    }

    /// Copies the current snapshot (§8.3). The revealed temporary password is
    /// only present on the single copy following a reveal command (§9.2).
    public func copySnapshot() throws -> HostCoreSnapshot {
        var bytes = RdnHostOwnedBytes(data: nil, length: 0, capacity: 0)
        lock.lock()
        let result = host.map {
            rdn_shim_host_copy_snapshot(library, $0, &bytes)
        } ?? Int32(RDN_HOST_ERR_BAD_STATE)
        lock.unlock()
        guard result == Int32(RDN_HOST_OK), let data = bytes.data else {
            throw HostControlError.snapshot(result)
        }
        let payload = Data(bytes: data, count: bytes.length)
        rdn_shim_host_free_bytes(library, bytes)
        guard let object = try? JSONSerialization.jsonObject(with: payload),
            let json = object as? [String: Any]
        else {
            throw HostControlError.snapshotDecode("snapshot is not a JSON object")
        }
        let presentation = json["temporaryPasswordPresentation"] as? [String: Any] ?? [:]
        let policy = presentation["policy"] as? String ?? "redacted"
        return HostCoreSnapshot(
            schemaVersion: (json["schemaVersion"] as? NSNumber)?.intValue ?? 0,
            hostInstanceId: json["hostInstanceId"] as? String ?? "",
            hostState: json["hostState"] as? String ?? "",
            localId: json["localId"] as? String ?? "",
            registrationStatus: json["registrationStatus"] as? String ?? "",
            temporaryPasswordPolicy: policy,
            revealedTemporaryPassword: policy == "revealed" ? presentation["value"] as? String : nil,
            lastError: json["lastError"] as? String,
            observedAt: UInt64((json["observedAt"] as? NSNumber)?.uint64Value ?? 0),
            rawJSON: payload
        )
    }

    public func setMediaCapabilities(
        hostInstanceID: String,
        capabilities: HostEncoderCapabilities
    ) throws {
        lock.lock()
        let result: Int32
        if let handle = host {
            result = hostInstanceID.withCString { instanceID in
                var raw = RdnHostEncoderCapabilities(
                    abi_version: Self.hostMediaABIVersion,
                    host_instance_id: instanceID,
                    h264_hardware: capabilities.h264Hardware ? 1 : 0,
                    h265_hardware: capabilities.h265Hardware ? 1 : 0,
                    max_width: capabilities.maxWidth,
                    max_height: capabilities.maxHeight,
                    max_fps: capabilities.maxFPS
                )
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
                        abi_version: Self.hostMediaABIVersion,
                        host_instance_id: instanceID,
                        connection_epoch: accessUnit.connectionEpoch,
                        codec_epoch: accessUnit.codecEpoch,
                        display_id: accessUnit.displayID,
                        display_revision: accessUnit.displayRevision,
                        codec: RdnHostMediaCodec(rawValue: accessUnit.codec.rawValue),
                        framing: RdnHostMediaFraming(rawValue: accessUnit.framing.rawValue),
                        flags: flags,
                        pts_us: accessUnit.presentationTimeUS,
                        data: bytes.bindMemory(to: UInt8.self).baseAddress,
                        length: accessUnit.data.count
                    )
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
        hostInstanceID: String,
        connectionEpoch: UInt64,
        codecEpoch: UInt64,
        codec: HostMediaCodec,
        hardwareAccelerated: Bool,
        softwareFallback: Bool,
        encoderID: String
    ) throws {
        lock.lock()
        let result: Int32
        if let handle = host {
            result = hostInstanceID.withCString { instanceID in
                encoderID.withCString { encoderID in
                    var raw = RdnHostEncoderState(
                        abi_version: Self.hostMediaABIVersion,
                        host_instance_id: instanceID,
                        connection_epoch: connectionEpoch,
                        codec_epoch: codecEpoch,
                        codec: RdnHostMediaCodec(rawValue: codec.rawValue),
                        hardware_accelerated: hardwareAccelerated ? 1 : 0,
                        software_fallback: softwareFallback ? 1 : 0,
                        encoder_id: encoderID
                    )
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
        let result = rdn_shim_host_stop(library, handle, RdnHostStopReason(rawValue: reason.rawValue))
        rdn_shim_host_destroy(library, handle)
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.stop(result)
        }
    }
}
