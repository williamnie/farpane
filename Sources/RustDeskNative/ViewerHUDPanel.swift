import AppKit

/// HUD 的鼠标事件留在本地，拖动不会变成远端点击或拖拽。
final class ViewerHUDPanel: NSVisualEffectView {
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStart: (point: NSPoint, origin: NSPoint)?

    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let superview else { return }
        dragStart = (superview.convert(event.locationInWindow, from: nil), frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview, let dragStart else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        onDrag?(
            NSPoint(
                x: dragStart.origin.x + point.x - dragStart.point.x,
                y: dragStart.origin.y + point.y - dragStart.point.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

enum ViewerHUDPlacement {
    static func clamp(_ origin: NSPoint, size: NSSize, within bounds: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)))
    }

    static func origin(for position: NSPoint, size: NSSize, within bounds: NSRect) -> NSPoint {
        NSPoint(
            x: bounds.minX + position.x * max(0, bounds.width - size.width),
            y: bounds.minY + position.y * max(0, bounds.height - size.height))
    }

    static func position(for origin: NSPoint, size: NSSize, within bounds: NSRect) -> NSPoint {
        let origin = clamp(origin, size: size, within: bounds)
        let width = bounds.width - size.width
        let height = bounds.height - size.height
        return NSPoint(
            x: width > 0 ? (origin.x - bounds.minX) / width : 0.5,
            y: height > 0 ? (origin.y - bounds.minY) / height : 0.5)
    }
}
