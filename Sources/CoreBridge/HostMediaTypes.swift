import CoreBridgeShim
import Foundation

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
        h264Hardware: Bool, h265Hardware: Bool, maxWidth: UInt32, maxHeight: UInt32, maxFPS: UInt32
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
        hostInstanceID: String, connectionEpoch: UInt64, codecEpoch: UInt64, displayID: UInt64,
        displayRevision: UInt64, codec: HostMediaCodec, framing: HostMediaFraming,
        presentationTimeUS: UInt64, isKeyframe: Bool, hasParameterSets: Bool, data: Data
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
