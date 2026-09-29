import CoreBridgeShim
import Foundation

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
        rendezvousServer: String, serverPublicKey: String, peerID: String, password: String = "",
        forceRelay: Bool = false, receiveAudio: Bool = false, receiveClipboardText: Bool = false,
        sendClipboardText: Bool = false, receiveClipboardRichText: Bool = false,
        sendClipboardRichText: Bool = false, receiveClipboardImage: Bool = false,
        sendClipboardImage: Bool = false, fileTransferEnabled: Bool = false,
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
        kind: CorePointerKind, x: Int32 = 0, y: Int32 = 0, scrollX: Int32 = 0, scrollY: Int32 = 0,
        buttons: CorePointerButtons = [], modifiers: CoreInputModifiers = []
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
