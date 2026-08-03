import CoreGraphics
import XCTest
import ViewerInput

final class AspectFitCoordinateMapperTests: XCTestCase {
    func testMapsPillarboxedAspectFitAndRejectsLetterbox() {
        let mapper = AspectFitCoordinateMapper(
            remoteSize: CGSize(width: 1920, height: 1080),
            viewSizePoints: CGSize(width: 1000, height: 1000),
            backingScale: 1
        )
        XCTAssertEqual(mapper.contentRectPoints.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(mapper.contentRectPoints.minY, 218.75, accuracy: 0.0001)
        XCTAssertEqual(mapper.contentRectPoints.width, 1000, accuracy: 0.0001)
        XCTAssertEqual(mapper.contentRectPoints.height, 562.5, accuracy: 0.0001)
        XCTAssertNil(mapper.map(pointInViewPoints: CGPoint(x: 500, y: 100)))
        XCTAssertEqual(
            mapper.map(pointInViewPoints: CGPoint(x: 500, y: 500)),
            RemotePoint(x: 960, y: 540)
        )
    }

    func testRetinaBackingScaleDoesNotChangeRemoteMapping() {
        let oneX = AspectFitCoordinateMapper(
            remoteSize: CGSize(width: 4096, height: 2304),
            viewSizePoints: CGSize(width: 1280, height: 720),
            backingScale: 1
        )
        let twoX = AspectFitCoordinateMapper(
            remoteSize: CGSize(width: 4096, height: 2304),
            viewSizePoints: CGSize(width: 1280, height: 720),
            backingScale: 2
        )
        let point = CGPoint(x: 320, y: 180)
        XCTAssertEqual(oneX.map(pointInViewPoints: point), RemotePoint(x: 1024, y: 576))
        XCTAssertEqual(twoX.map(pointInViewPoints: point), oneX.map(pointInViewPoints: point))
    }

    func testClampsDragOutsideContentToRemoteEdges() {
        let mapper = AspectFitCoordinateMapper(
            remoteSize: CGSize(width: 100, height: 50),
            viewSizePoints: CGSize(width: 200, height: 200),
            backingScale: 2
        )
        XCTAssertEqual(
            mapper.map(pointInViewPoints: CGPoint(x: -10, y: 500), clampToContent: true),
            RemotePoint(x: 0, y: 49)
        )
        XCTAssertEqual(
            mapper.map(pointInViewPoints: CGPoint(x: 200, y: 200), clampToContent: true),
            RemotePoint(x: 99, y: 49)
        )
    }

    func testMapsExactBottomRightBoundaryInsideRemoteBounds() {
        let mapper = AspectFitCoordinateMapper(
            remoteSize: CGSize(width: 10, height: 10),
            viewSizePoints: CGSize(width: 100, height: 100),
            backingScale: 1
        )
        XCTAssertEqual(
            mapper.map(pointInViewPoints: CGPoint(x: 100, y: 100), clampToContent: true),
            RemotePoint(x: 9, y: 9)
        )
    }
}
