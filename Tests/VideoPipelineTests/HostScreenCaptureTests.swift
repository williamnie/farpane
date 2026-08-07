import CoreVideo
import XCTest
@testable import VideoPipeline

final class HostScreenCaptureTests: XCTestCase {
    func testClassifiesBiPlanarFormatsAsZeroCopy() {
        for format in [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ] {
            let path = HostCapturePixelPath.classify(pixelFormat: format)
            XCTAssertEqual(path, .biPlanarDirect)
            XCTAssertEqual(path?.logicalRawFrameCopyCount, 0)
        }
    }

    func testClassifiesBGRAAsOnePixelTransferAndRejectsUnknownFormats() {
        let path = HostCapturePixelPath.classify(pixelFormat: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(path, .bgraPixelTransfer)
        XCTAssertEqual(path?.logicalRawFrameCopyCount, 1)
        XCTAssertNil(HostCapturePixelPath.classify(pixelFormat: kCVPixelFormatType_24RGB))
    }

    func testCaptureConfigurationBoundsAndPreferenceOrder() {
        XCTAssertTrue(HostCaptureConfiguration(
            displayIndex: 0,
            width: 3840,
            height: 2160,
            framesPerSecond: 30
        ).isValid)
        XCTAssertFalse(HostCaptureConfiguration(
            displayIndex: -1,
            width: 3840,
            height: 2160,
            framesPerSecond: 30
        ).isValid)
        XCTAssertFalse(HostCaptureConfiguration(
            displayIndex: 0,
            width: 3840,
            height: 2160,
            framesPerSecond: 0
        ).isValid)
        XCTAssertEqual(HostScreenCaptureAdapter.preferredPixelFormats, [
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ])
    }
}
