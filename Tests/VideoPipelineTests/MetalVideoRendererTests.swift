import CoreGraphics
import Metal
import XCTest
@testable import VideoPipeline

final class MetalVideoRendererTests: XCTestCase {
    func testAutomaticPreferenceUsesSystemDefaultDevice() throws {
        let systemDefault = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let selected = try XCTUnwrap(MetalVideoRenderer.selectDevice(.automatic))

        XCTAssertEqual(selected.registryID, systemDefault.registryID)
    }

    func testAutomaticPreferenceUsesCurrentDisplayDevice() throws {
        let displayID = CGMainDisplayID()
        guard let displayDevice = CGDirectDisplayCopyCurrentMetalDevice(displayID) else {
            throw XCTSkip("current display has no Metal device")
        }
        let selected = try XCTUnwrap(
            MetalVideoRenderer.selectDevice(.automatic, displayID: displayID)
        )

        XCTAssertEqual(selected.registryID, displayDevice.registryID)
    }
}
