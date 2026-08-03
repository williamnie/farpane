import AppKit
import CoreBridge
import CoreGraphics

public enum MacKeyMapper {
    public static func key(keyCode: UInt16, charactersIgnoringModifiers: String?) -> CoreKey? {
        switch keyCode {
        case 53: return .special(.escape)
        case 36, 76: return .special(.return)
        case 48: return .special(.tab)
        case 51: return .special(.backspace)
        case 117: return .special(.deleteForward)
        case 123: return .special(.left)
        case 124: return .special(.right)
        case 125: return .special(.down)
        case 126: return .special(.up)
        case 49: return .special(.space)
        case 56, 60: return .special(.shift)
        case 59, 62: return .special(.control)
        case 58, 61: return .special(.option)
        case 54, 55: return .special(.command)
        case 115: return .special(.home)
        case 119: return .special(.end)
        case 116: return .special(.pageUp)
        case 121: return .special(.pageDown)
        default:
            guard let scalar = charactersIgnoringModifiers?.unicodeScalars.first,
                  !CharacterSet.controlCharacters.contains(scalar) else { return nil }
            return .character(scalar)
        }
    }

    /// Maps physical ANSI key positions without consulting AppKit text input.
    /// The exclusive event-tap callback runs on a background run loop, while
    /// macOS 13 requires Text Input Services character lookup on the main queue.
    public static func keyFromHardwareCode(_ keyCode: UInt16) -> CoreKey? {
        if let special = key(keyCode: keyCode, charactersIgnoringModifiers: nil) {
            return special
        }
        guard let scalar = ansiCharacters[keyCode] else { return nil }
        return .character(scalar)
    }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> CoreInputModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: CoreInputModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    public static func modifiers(from flags: CGEventFlags) -> CoreInputModifiers {
        var result: CoreInputModifiers = []
        if flags.contains(.maskShift) { result.insert(.shift) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        return result
    }

    public static func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        switch keyCode {
        case 56, 60: return flags.contains(.shift)
        case 59, 62: return flags.contains(.control)
        case 58, 61: return flags.contains(.option)
        case 54, 55: return flags.contains(.command)
        default: return nil
        }
    }

    public static func modifierIsDown(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        switch keyCode {
        case 56, 60: return flags.contains(.maskShift)
        case 59, 62: return flags.contains(.maskControl)
        case 58, 61: return flags.contains(.maskAlternate)
        case 54, 55: return flags.contains(.maskCommand)
        default: return nil
        }
    }

    private static let ansiCharacters: [UInt16: Unicode.Scalar] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 50: "`",
    ]
}
