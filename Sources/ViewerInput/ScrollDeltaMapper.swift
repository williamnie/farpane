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
    private static let magnificationToPixelScale = 1_000.0

    /// 每个 Viewer 独立累计像素小数，避免平滑滚动的尾段被放大或直接丢失。
    public struct Accumulator {
        private var remainderX = 0.0
        private var remainderY = 0.0

        public init() {}

        public mutating func reset() {
            remainderX = 0
            remainderY = 0
        }

        public mutating func map(deltaX: Double, deltaY: Double, precise: Bool)
            -> RemoteScrollDelta?
        {
            guard precise else {
                reset()
                return ScrollDeltaMapper.map(deltaX: deltaX, deltaY: deltaY, precise: false)
            }
            let x = accumulate(deltaX, remainder: &remainderX)
            let y = accumulate(deltaY, remainder: &remainderY)
            guard x != 0 || y != 0 else { return nil }
            return RemoteScrollDelta(kind: .preciseScroll, x: x, y: y)
        }

        private func accumulate(_ value: Double, remainder: inout Double) -> Int32 {
            guard value.isFinite else {
                remainder = 0
                return 0
            }
            let total = remainder + max(-120, min(120, value))
            let whole = Int32(total.rounded(.towardZero))
            remainder = total - Double(whole)
            return whole
        }
    }

    public static func map(deltaX: Double, deltaY: Double, precise: Bool) -> RemoteScrollDelta? {
        let x = quantize(deltaX, precise: precise)
        let y = quantize(deltaY, precise: precise)
        guard x != 0 || y != 0 else { return nil }
        return RemoteScrollDelta(kind: precise ? .preciseScroll : .scroll, x: x, y: y)
    }

    /// Maps AppKit's fractional magnification delta to the pixel-scale scroll
    /// convention used by RustDesk's touch gesture implementation.
    public static func map(magnification: Double) -> RemoteScrollDelta? {
        let value = magnification * magnificationToPixelScale
        guard value.isFinite, value != 0 else { return nil }
        let magnitude = Int32(max(3, min(120, abs(value).rounded())))
        return RemoteScrollDelta(kind: .preciseScroll, x: 0, y: value > 0 ? magnitude : -magnitude)
    }

    private static func quantize(_ value: Double, precise: Bool) -> Int32 {
        guard value.isFinite, value != 0 else { return 0 }
        let magnitude: Int32
        if precise {
            // 精细滚动使用像素单位；先限幅再转整数，避免极大输入溢出。
            magnitude = Int32(min(120, abs(value)).rounded(.towardZero))
        } else {
            // 协议单位是滚轮档位，不是目标应用的文本行数。
            magnitude = 1
        }
        return value > 0 ? magnitude : -magnitude
    }
}
