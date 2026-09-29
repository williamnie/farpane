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

public enum CoreRemotePermission: UInt32, Equatable, Sendable { case audio = 1 }

public struct CoreRemotePermissionEvent: Equatable, Sendable {
    public let connectionEpoch: UInt64
    public let permission: CoreRemotePermission
    public let enabled: Bool

    public init(connectionEpoch: UInt64, permission: CoreRemotePermission, enabled: Bool) {
        self.connectionEpoch = connectionEpoch
        self.permission = permission
        self.enabled = enabled
    }
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
