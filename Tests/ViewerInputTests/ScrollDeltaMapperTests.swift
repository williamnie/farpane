import CoreBridge
import ViewerInput
import XCTest

final class ScrollDeltaMapperTests: XCTestCase {
    func testSmoothScrollTailDoesNotBecomeMultipleWheelSteps() {
        XCTAssertNil(ScrollDeltaMapper.map(deltaX: 0, deltaY: 0.2, precise: true))
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 0, deltaY: 1, precise: false),
            RemoteScrollDelta(kind: .scroll, x: 0, y: 1))
    }

    func testPreservesPreciseMagnitudeAndUsesTrackpadSemantics() {
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 0, deltaY: -18.4, precise: true),
            RemoteScrollDelta(kind: .preciseScroll, x: 0, y: -18))
        XCTAssertNil(ScrollDeltaMapper.map(deltaX: 0.2, deltaY: 0, precise: true))
    }

    func testMapsDiscreteWheelToSingleNotchesAndBoundsBursts() {
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 0, deltaY: 1, precise: false),
            RemoteScrollDelta(kind: .scroll, x: 0, y: 1))
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: 1_000, deltaY: 0, precise: true),
            RemoteScrollDelta(kind: .preciseScroll, x: 120, y: 0))
        XCTAssertNil(ScrollDeltaMapper.map(deltaX: 0, deltaY: 0, precise: true))
    }

    func testAccumulatesSmoothPixelsWithoutAmplifyingEachEvent() {
        var mapper = ScrollDeltaMapper.Accumulator()
        for _ in 0..<4 { XCTAssertNil(mapper.map(deltaX: 0.2, deltaY: -0.2, precise: true)) }
        XCTAssertEqual(
            mapper.map(deltaX: 0.2, deltaY: -0.2, precise: true),
            RemoteScrollDelta(kind: .preciseScroll, x: 1, y: -1))
        var sum: Int32 = 0
        for _ in 0..<100 { sum += mapper.map(deltaX: 0, deltaY: 18.5, precise: true)?.y ?? 0 }
        XCTAssertEqual(sum, 1_850)
    }

    func testAccumulatorResetIsolationAndDiscreteInputDiscardRemainders() {
        var first = ScrollDeltaMapper.Accumulator()
        var second = ScrollDeltaMapper.Accumulator()
        XCTAssertNil(first.map(deltaX: 0, deltaY: 0.75, precise: true))
        XCTAssertNil(second.map(deltaX: 0, deltaY: 0.5, precise: true))
        first.reset()
        XCTAssertNil(first.map(deltaX: 0, deltaY: 0.5, precise: true))
        XCTAssertEqual(first.map(deltaX: 0, deltaY: -4, precise: false)?.y, -1)
        XCTAssertNil(first.map(deltaX: 0, deltaY: 0.75, precise: true))
    }

    func testExtremeAndNonfiniteDeltasAreSafe() {
        var mapper = ScrollDeltaMapper.Accumulator()
        XCTAssertEqual(
            mapper.map(deltaX: 0, deltaY: .greatestFiniteMagnitude, precise: true)?.y, 120)
        XCTAssertNil(mapper.map(deltaX: .nan, deltaY: .infinity, precise: true))
        XCTAssertEqual(
            ScrollDeltaMapper.map(deltaX: -.greatestFiniteMagnitude, deltaY: 0, precise: true)?.x,
            -120)
    }

    func testMapsMagnificationUsingRustDeskTouchScaleConvention() {
        XCTAssertEqual(
            ScrollDeltaMapper.map(magnification: 0.012),
            RemoteScrollDelta(kind: .preciseScroll, x: 0, y: 12))
        XCTAssertEqual(
            ScrollDeltaMapper.map(magnification: -0.0001),
            RemoteScrollDelta(kind: .preciseScroll, x: 0, y: -3))
        XCTAssertEqual(
            ScrollDeltaMapper.map(magnification: 1),
            RemoteScrollDelta(kind: .preciseScroll, x: 0, y: 120))
        XCTAssertNil(ScrollDeltaMapper.map(magnification: 0))
        XCTAssertNil(ScrollDeltaMapper.map(magnification: .infinity))
    }
}
