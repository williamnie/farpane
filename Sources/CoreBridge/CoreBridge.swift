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

    public var isKeyframe: Bool { flags & UInt32(RDN_VIDEO_FLAG_KEYFRAME.rawValue) != 0 }
    public var containsVPS: Bool { flags & UInt32(RDN_VIDEO_FLAG_VPS.rawValue) != 0 }
    public var containsSPS: Bool { flags & UInt32(RDN_VIDEO_FLAG_SPS.rawValue) != 0 }
    public var containsPPS: Bool { flags & UInt32(RDN_VIDEO_FLAG_PPS.rawValue) != 0 }
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

public struct CoreConnectionConfig: Sendable {
    public let rendezvousServer: String
    public let serverPublicKey: String
    public let peerID: String
    public let password: String
    public let forceRelay: Bool
    public let receiveClipboardText: Bool
    public let sendClipboardText: Bool
    public let receiveClipboardRichText: Bool
    public let sendClipboardRichText: Bool

    public init(
        rendezvousServer: String,
        serverPublicKey: String,
        peerID: String,
        password: String = "",
        forceRelay: Bool = false,
        receiveClipboardText: Bool = false,
        sendClipboardText: Bool = false,
        receiveClipboardRichText: Bool = false,
        sendClipboardRichText: Bool = false
    ) {
        self.rendezvousServer = rendezvousServer
        self.serverPublicKey = serverPublicKey
        self.peerID = peerID
        self.password = password
        self.forceRelay = forceRelay
        self.receiveClipboardText = receiveClipboardText
        self.sendClipboardText = sendClipboardText
        self.receiveClipboardRichText = receiveClipboardRichText
        self.sendClipboardRichText = sendClipboardRichText
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

private final class CallbackBox: @unchecked Sendable {
    let queue: DispatchQueue
    let onState: @Sendable (CoreStateEvent) -> Void
    let onVideo: @Sendable (CoreVideoPacket) -> Void
    let onMetrics: @Sendable (CoreRuntimeMetrics) -> Void
    let onClipboardText: @Sendable (String) -> Void
    let onClipboardRichText: @Sendable (CoreClipboardRichTextPayload) -> Void
    private let clipboardLifecycleLock = NSLock()
    private var clipboardDeliveryEnabled = true

    init(
        queue: DispatchQueue,
        onState: @escaping @Sendable (CoreStateEvent) -> Void,
        onVideo: @escaping @Sendable (CoreVideoPacket) -> Void,
        onMetrics: @escaping @Sendable (CoreRuntimeMetrics) -> Void,
        onClipboardText: @escaping @Sendable (String) -> Void,
        onClipboardRichText: @escaping @Sendable (CoreClipboardRichTextPayload) -> Void
    ) {
        self.queue = queue
        self.onState = onState
        self.onVideo = onVideo
        self.onMetrics = onMetrics
        self.onClipboardText = onClipboardText
        self.onClipboardRichText = onClipboardRichText
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

    func stopClipboardDelivery() {
        clipboardLifecycleLock.withLock {
            clipboardDeliveryEnabled = false
        }
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

private let videoCallback: RDNVideoCallback = { context, framePointer in
    guard let context, let framePointer else { return }
    let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
    let frame = framePointer.pointee
    guard frame.abi_version == RDN_ABI_VERSION, let bytes = frame.data else { return }
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
        display: frame.display
    )
    box.queue.async { box.onVideo(packet) }
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
        onClipboardText: @escaping @Sendable (String) -> Void = { _ in },
        onClipboardRichText: @escaping @Sendable (CoreClipboardRichTextPayload) -> Void = { _ in }
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

        let callbackBox = CallbackBox(
            queue: callbackQueue,
            onState: onState,
            onVideo: onVideo,
            onMetrics: onMetrics,
            onClipboardText: onClipboardText,
            onClipboardRichText: onClipboardRichText
        )
        var callbacks = RDNCallbacks(
            abi_version: RDN_ABI_VERSION,
            on_state: stateCallback,
            on_video: videoCallback,
            on_metrics: metricsCallback,
            on_clipboard_text: clipboardTextCallback,
            on_clipboard_rich_text: clipboardRichTextCallback
        )
        let context = Unmanaged.passUnretained(callbackBox).toOpaque()
        guard let client = rdn_shim_client_create(library, &callbacks, context) else {
            rdn_shim_close(library)
            throw CoreBridgeError.createClient
        }
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
                            receive_clipboard_text: config.receiveClipboardText,
                            send_clipboard_text: config.sendClipboardText,
                            receive_clipboard_rich_text: config.receiveClipboardRichText,
                            send_clipboard_rich_text: config.sendClipboardRichText
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
            callbackBox.stopClipboardDelivery()
            rdn_shim_client_disconnect(library, client)
        }
    }

    @discardableResult
    public func requestKeyframe(display: UInt32) -> Bool {
        rdn_shim_client_request_keyframe(library, client, display) == 0
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
