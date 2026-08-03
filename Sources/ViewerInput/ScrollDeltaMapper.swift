import CoreBridge
import Foundation

public struct RemoteScrollDelta: Equatable, Sendable {
    public let kind: CorePointerKind
    public let x: Int32
    public let y: Int32

    public init(kind: CorePointerKind, x: Int32, y: Int32) {
        self.kind = kind
        self.x = x
        self.y = y
    }
}

public enum ScrollDeltaMapper {
    public static func map(deltaX: Double, deltaY: Double, precise: Bool) -> RemoteScrollDelta? {
        let x = quantize(deltaX, precise: precise)
        let y = quantize(deltaY, precise: precise)
        guard x != 0 || y != 0 else { return nil }
        return RemoteScrollDelta(kind: precise ? .preciseScroll : .scroll, x: x, y: y)
    }

    private static func quantize(_ value: Double, precise: Bool) -> Int32 {
        guard value.isFinite, value != 0 else { return 0 }
        let magnitude: Int32
        if precise {
            // RustDesk's macOS receiver interprets precise deltas as pixels. Keep
            // at least the upstream three-pixel floor while preserving larger
            // AppKit deltas instead of collapsing every event to one pixel.
            magnitude = max(3, min(120, Int32(abs(value).rounded())))
        } else {
            // A conventional wheel notch is three lines on macOS.
            magnitude = 3
        }
        return value > 0 ? magnitude : -magnitude
    }
}
