import CoreBridgeShim
import Foundation

public enum HostStopReason: UInt32, Sendable {
    case userRequest = 0
    case appExit = 1
    case error = 2
}

public enum HostSleepRecoveryOperation: String, Equatable, Sendable {
    case beginSleep
    case finishSleep
    case resumeAfterWake
}

public enum HostSleepRecoveryFailure: Equatable, Sendable {
    case invalidEpoch
    case staleEpoch
    case invalidState
    case unsupported
    case internalFailure
    case unknown
}

public enum HostNetworkPathRecoveryFailure: Equatable, Sendable {
    case staleGeneration
    case invalidState
    case unsupported
    case internalFailure
    case unknown
}

/// Canonical self-hosted RustDesk server configuration. The public key is
/// hbbs `key.pub`; it authenticates the server and is never an SSH credential.
public struct HostServerConfiguration: Sendable {
    public let rendezvousServer: String
    public let relayServer: String
    public let serverPublicKey: String
    public let clipboardReadEnabled: Bool
    public let clipboardWriteEnabled: Bool
    public let clipboardRichTextReadEnabled: Bool
    public let clipboardRichTextWriteEnabled: Bool
    public let clipboardImageReadEnabled: Bool
    public let clipboardImageWriteEnabled: Bool
    public let audioEnabled: Bool
    public let audioInputDeviceName: String?
    public let fileTransferEnabled: Bool
    public let fileTransferReceiveRoot: String?

    public init(
        rendezvousServer: String, relayServer: String = "", serverPublicKey: String,
        clipboardReadEnabled: Bool = false, clipboardWriteEnabled: Bool = false,
        clipboardRichTextReadEnabled: Bool = false, clipboardRichTextWriteEnabled: Bool = false,
        clipboardImageReadEnabled: Bool = false, clipboardImageWriteEnabled: Bool = false,
        audioEnabled: Bool = false, audioInputDeviceName: String? = nil,
        fileTransferEnabled: Bool = false, fileTransferReceiveRoot: String? = nil
    ) {
        self.rendezvousServer = rendezvousServer
        self.relayServer = relayServer
        self.serverPublicKey = serverPublicKey
        self.clipboardReadEnabled = clipboardReadEnabled
        self.clipboardWriteEnabled = clipboardWriteEnabled
        self.clipboardRichTextReadEnabled = clipboardRichTextReadEnabled
        self.clipboardRichTextWriteEnabled = clipboardRichTextWriteEnabled
        self.clipboardImageReadEnabled = clipboardImageReadEnabled
        self.clipboardImageWriteEnabled = clipboardImageWriteEnabled
        self.audioEnabled = audioEnabled
        self.audioInputDeviceName = audioInputDeviceName
        self.fileTransferEnabled = fileTransferEnabled
        self.fileTransferReceiveRoot = fileTransferReceiveRoot
    }
}
