import CoreVideo
import Foundation
import ScreenCaptureKit
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

    func testOnlyIdleFrameStatusEntersMissingDirtyMetadataFallback() {
        XCTAssertEqual(
            HostScreenCaptureAdapter.disposition(for: .complete),
            .complete
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.disposition(for: .idle),
            .idleFallback
        )
        for status in [
            SCFrameStatus.blank,
            .suspended,
            .started,
            .stopped,
        ] {
            XCTAssertEqual(
                HostScreenCaptureAdapter.disposition(for: status),
                .ignore
            )
        }
    }

    func testClassifiesOnlySanitizedMetadataAvailability() {
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: nil),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .missingOrInvalid,
                completeFrameDirtyRects: nil
            )
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: [
                .status: NSNumber(value: 999),
            ]),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .unknown,
                completeFrameDirtyRects: nil
            )
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: [
                .status: NSNumber(value: SCFrameStatus.complete.rawValue),
            ]),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .complete,
                completeFrameDirtyRects: .absent
            )
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: [
                .status: NSNumber(value: SCFrameStatus.complete.rawValue),
                .dirtyRects: "unexpected",
            ]),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .complete,
                completeFrameDirtyRects: .unrecognized
            )
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: [
                .status: NSNumber(value: SCFrameStatus.complete.rawValue),
                .dirtyRects: [NSValue](),
            ]),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .complete,
                completeFrameDirtyRects: .recognizedEmpty
            )
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: [
                .status: NSNumber(value: SCFrameStatus.complete.rawValue),
                .dirtyRects: [NSValue(rect: CGRect(x: 1, y: 2, width: 3, height: 4))],
            ]),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .complete,
                completeFrameDirtyRects: .recognizedNonEmpty
            )
        )
        XCTAssertEqual(
            HostScreenCaptureAdapter.metadataAvailability(from: [
                .status: NSNumber(value: SCFrameStatus.idle.rawValue),
                .dirtyRects: [NSValue(rect: CGRect(x: 1, y: 2, width: 3, height: 4))],
            ]),
            HostCaptureSampleMetadataAvailability(
                frameStatus: .idle,
                completeFrameDirtyRects: nil
            )
        )
    }
}
