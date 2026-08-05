import CoreBridgeShim
import Foundation

/// Contract errors for the Host Control ABI (§8.1). Codes mirror the stable
/// `RDN_HOST_ERR_*` values so callers can distinguish fail-closed states.
public enum HostControlError: Error, CustomStringConvertible {
    case load(String)
    case hostSurfaceUnavailable
    case abiMismatch(found: UInt32)
    case invalidUpstreamCommit(String)
    case configRoot(Int32)
    case create(Int32)
    case start(Int32)
    case command(Int32)
    case snapshot(Int32)
    case snapshotDecode(String)
    case stop(Int32)

    public var description: String {
        switch self {
        case .load(let message): return "Host core load failed: \(message)"
        case .hostSurfaceUnavailable: return "core library has no host ABI surface"
        case .abiMismatch(let found): return "host ABI version mismatch: \(found)"
        case .invalidUpstreamCommit(let commit): return "unexpected RustDesk core commit: \(commit)"
        case .configRoot(let code): return "config-root switch rejected: \(code)"
        case .create(let code): return "host create failed: \(code)"
        case .start(let code): return "host start failed: \(code)"
        case .command(let code): return "host command rejected: \(code)"
        case .snapshot(let code): return "host snapshot copy failed: \(code)"
        case .snapshotDecode(let message): return "host snapshot decode failed: \(message)"
        case .stop(let code): return "host stop failed: \(code)"
        }
    }
}

public enum HostStopReason: UInt32, Sendable {
    case userRequest = 0
    case appExit = 1
    case error = 2
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
    guard let object = try? JSONSerialization.jsonObject(with: data),
        let envelope = object as? [String: Any]
    else { return }
    let event = HostCoreEvent(
        schemaVersion: (envelope["schemaVersion"] as? NSNumber)?.intValue ?? 0,
        eventId: UInt64((envelope["eventId"] as? NSNumber)?.uint64Value ?? 0),
        eventType: envelope["eventType"] as? String ?? "",
        hostInstanceId: envelope["hostInstanceId"] as? String ?? "",
        sentAt: UInt64((envelope["sentAt"] as? NSNumber)?.uint64Value ?? 0),
        rawJSON: data
    )
    box.queue.async { box.onEvent(event) }
}

/// Swift-side HostCore control surface (§6.3, §8.2). Wraps the shimmed
/// `rdn_host_*` ABI with one library handle per process; host and viewer
/// cores remain mutually exclusive (§18 rule 1).
public final class HostControlClient: @unchecked Sendable {
    public static let hostABIVersion = UInt32(RDN_HOST_ABI_VERSION)
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
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard host == nil else { return }
        var options = RdnHostCreateOptions(abi_version: Self.hostABIVersion)
        var callbacks = RdnHostCallbacks(
            abi_version: Self.hostABIVersion,
            on_event: hostEventCallback,
            context: Unmanaged.passUnretained(eventBox).toOpaque()
        )
        var handle: OpaquePointer?
        let created = rdn_shim_host_create(library, &options, &callbacks, &handle)
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
        let handle = lockedHost()
        let result = data.withUnsafeBytes { buffer in
            rdn_shim_host_command(
                library, handle, buffer.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
        guard result == Int32(RDN_HOST_OK) else {
            throw HostControlError.command(result)
        }
    }

    /// Copies the current snapshot (§8.3). The revealed temporary password is
    /// only present on the single copy following a reveal command (§9.2).
    public func copySnapshot() throws -> HostCoreSnapshot {
        let handle = lockedHost()
        var bytes = RdnHostOwnedBytes(data: nil, length: 0, capacity: 0)
        let result = rdn_shim_host_copy_snapshot(library, handle, &bytes)
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

    private func lockedHost() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }
}
