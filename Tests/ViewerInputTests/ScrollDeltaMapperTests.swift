import CoreBridge
import ViewerInput
import XCTest

final class ScrollDeltaMapperTests: XCTestCase {
    func testPreservesPreciseMagnitudeAndUsesTrackpadSemantics() {
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 0, deltaY: -18.4, precise: true),
            RemoteScrollDelta(kind: .preciseScroll, x: 0, y: -18)
        )
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 0.2, deltaY: 0, precise: true),
            RemoteScrollDelta(kind: .preciseScroll, x: 3, y: 0)
        )
    }

    func testMapsDiscreteWheelToThreeLineNotchesAndBoundsBursts() {
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 0, deltaY: 1, precise: false),
            RemoteScrollDelta(kind: .scroll, x: 0, y: 3)
        )
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 1_000, deltaY: 0, precise: true),
            RemoteScrollDelta(kind: .preciseScroll, x: 120, y: 0)
        )
        XCTAssertNil(ScrollDeltaMapper.map(deltaX: 0, deltaY: 0, precise: true))
    }
}
