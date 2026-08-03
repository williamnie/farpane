import CoreGraphics
import Foundation

public struct RemotePoint: Equatable, Sendable {
    public let x: Int32
    public let y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

public struct AspectFitCoordinateMapper: Sendable {
    public let remoteSize: CGSize
    public let viewSizePoints: CGSize
    public let backingScale: CGFloat
    public let contentRectPixels: CGRect

    public init(remoteSize: CGSize, viewSizePoints: CGSize, backingScale: CGFloat) {
        self.remoteSize = remoteSize
        self.viewSizePoints = viewSizePoints
        self.backingScale = max(0.01, backingScale)

        let viewPixels = CGSize(
            width: max(0, viewSizePoints.width * self.backingScale),
            height: max(0, viewSizePoints.height * self.backingScale)
        )
        guard remoteSize.width > 0, remoteSize.height > 0,
              viewPixels.width > 0, viewPixels.height > 0 else {
            contentRectPixels = .zero
            return
        }
        let scale = min(
            viewPixels.width / remoteSize.width,
            viewPixels.height / remoteSize.height
        )
        let fitted = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        contentRectPixels = CGRect(
            x: (viewPixels.width - fitted.width) / 2,
            y: (viewPixels.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    public var contentRectPoints: CGRect {
        CGRect(
            x: contentRectPixels.minX / backingScale,
            y: contentRectPixels.minY / backingScale,
            width: contentRectPixels.width / backingScale,
            height: contentRectPixels.height / backingScale
        )
    }

    public func map(pointInViewPoints point: CGPoint, clampToContent: Bool = false) -> RemotePoint? {
        guard remoteSize.width >= 1, remoteSize.height >= 1,
              contentRectPixels.width > 0, contentRectPixels.height > 0 else { return nil }
        var pixelPoint = CGPoint(x: point.x * backingScale, y: point.y * backingScale)
        if !contentRectPixels.contains(pixelPoint) {
            guard clampToContent else { return nil }
            pixelPoint.x = min(max(pixelPoint.x, contentRectPixels.minX), contentRectPixels.maxX)
            pixelPoint.y = min(max(pixelPoint.y, contentRectPixels.minY), contentRectPixels.maxY)
        }
        let normalizedX = (pixelPoint.x - contentRectPixels.minX) / contentRectPixels.width
        let normalizedY = (pixelPoint.y - contentRectPixels.minY) / contentRectPixels.height
        let maximumX = max(0, Int(remoteSize.width) - 1)
        let maximumY = max(0, Int(remoteSize.height) - 1)
        return RemotePoint(
            x: Int32(min(maximumX, max(0, Int(floor(normalizedX * remoteSize.width))))),
            y: Int32(min(maximumY, max(0, Int(floor(normalizedY * remoteSize.height)))))
        )
    }
}
