import AppKit
import ConnectionCatalog

final class BrandLogoView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 26),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let sx = bounds.width / 32
        let sy = bounds.height / 26
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * sx, y: y * sy) }

        let bridge = NSBezierPath()
        bridge.move(to: point(10.5, 9.2))
        bridge.line(to: point(21.5, 11.2))
        bridge.line(to: point(21.5, 16.0))
        bridge.line(to: point(10.5, 18.2))
        bridge.close()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.84, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.30, green: 0.70, blue: 1.0, alpha: 1),
        ])?.draw(in: bridge, angle: 0)

        let left = panePath(
            outerTop: point(2.5, 4.0), innerTop: point(12.2, 8.4), innerBottom: point(12.2, 19.0),
            outerBottom: point(2.5, 23.0), roundsLeftEdge: true)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.04, green: 0.57, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.98, alpha: 1),
        ])?.draw(in: left, angle: -35)

        let right = panePath(
            outerTop: point(29.5, 4.0), innerTop: point(19.8, 8.4), innerBottom: point(19.8, 19.0),
            outerBottom: point(29.5, 23.0), roundsLeftEdge: false)
        NSGradient(colors: [
            NSColor(calibratedRed: 0.61, green: 0.28, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.42, green: 0.20, blue: 0.96, alpha: 1),
        ])?.draw(in: right, angle: 35)
    }

    private func panePath(
        outerTop: NSPoint, innerTop: NSPoint, innerBottom: NSPoint, outerBottom: NSPoint,
        roundsLeftEdge: Bool
    ) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: outerTop)
        path.line(to: innerTop)
        path.curve(
            to: innerBottom, controlPoint1: NSPoint(x: innerTop.x, y: innerTop.y + 1.2),
            controlPoint2: NSPoint(x: innerBottom.x, y: innerBottom.y - 1.2))
        path.line(to: outerBottom)
        let edgeX = outerTop.x
        let direction: CGFloat = roundsLeftEdge ? -1 : 1
        path.curve(
            to: outerTop,
            controlPoint1: NSPoint(x: edgeX + direction * 0.8, y: outerBottom.y - 0.5),
            controlPoint2: NSPoint(x: edgeX + direction * 0.8, y: outerTop.y + 0.5))
        path.close()
        return path
    }
}

/// accent 纯色填充按钮（hover / 按下 / 禁用状态）
final class AccentButton: NSButton {
    private var isHovering = false
    private var isPressing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        isBordered = false
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 13.5, weight: .semibold)
        applyTitleStyle()
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet {
            applyTitleStyle()
            updateBackground()
        }
    }

    override var title: String { didSet { applyTitleStyle() } }

    private func applyTitleStyle() {
        let color: NSColor = isEnabled ? HomePalette.inkOnAccent : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: color, .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            ])
    }

    private func updateBackground() {
        guard let layer else { return }
        let accent = HomePalette.accent
        if !isEnabled {
            layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.4).cgColor
        } else if isPressing {
            layer.backgroundColor =
                (accent.blended(withFraction: 0.18, of: .black) ?? accent).cgColor
        } else if isHovering {
            layer.backgroundColor =
                (accent.blended(withFraction: 0.1, of: .white) ?? accent).cgColor
        } else {
            layer.backgroundColor = accent.cgColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        isPressing = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        updateBackground()
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        isPressing = false
        updateBackground()
        super.mouseUp(with: event)
    }
}

// MARK: - 设备行
